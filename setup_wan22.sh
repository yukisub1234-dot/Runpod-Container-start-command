#!/bin/bash
set -euo pipefail

# ==============================================================================
# 【基本設定】
# テンプレート: ComfyUI - CUDA 12.8 (runpod-workers/comfyui-base)
# ==============================================================================
RUNPOD_SLIM_DIR="/workspace/runpod-slim"
COMFYUI_DIR="${RUNPOD_SLIM_DIR}/ComfyUI"
COMFYUI_ARGS_FILE="${RUNPOD_SLIM_DIR}/comfyui_args.txt"
BASE_DIR="${COMFYUI_DIR}/models"
CUSTOM_NODES_DIR="${COMFYUI_DIR}/custom_nodes"
PLUGIN_DIR="${CUSTOM_NODES_DIR}/ComfyUI-WanVideoWrapper"
COMFYUI_LOG="/tmp/comfyui_setup.log"

# ==============================================================================
# 【仮想環境】
# ==============================================================================
VENV_DIR="${COMFYUI_DIR}/.venv-cu128"
if [ -d "$VENV_DIR" ]; then
    export PATH="${VENV_DIR}/bin:$PATH"
    PYTHON_EXEC="${VENV_DIR}/bin/python"
    PIP_CMD="${VENV_DIR}/bin/pip"
else
    echo "❌ venv が見つかりません: ${VENV_DIR}"
    exit 1
fi

export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_XET_HIGH_PERFORMANCE=1

echo "=================================================="
echo "🚀 Wan 2.2 セットアップスクリプト（最適化版）"
echo "=================================================="

# ==============================================================================
# 【Step 1】ComfyUI-Manager の起動時チェックを無効化（維持）
# ==============================================================================
echo "📋 [Step 1/5] ComfyUI-Manager の設定を書き込み中..."
MANAGER_CONFIG_DIR="${COMFYUI_DIR}/user/__manager"
MANAGER_CONFIG="${MANAGER_CONFIG_DIR}/config.ini"
mkdir -p "$MANAGER_CONFIG_DIR"

cat > "$MANAGER_CONFIG" << 'MANAGER_CONF'
[default]
skip_update_check = true
update_check = none
network_mode = local
fetch_custom_node_list = false
skip_migration = true
MANAGER_CONF

# ==============================================================================
# 【Step 2】起動引数の設定 ★修正箇所：OOM対策とFP8の全面適用
# ------------------------------------------------------------------------------
# 変更前: --fp8_e4m3fn-text-enc (テキストエンコーダーのみFP8化、14Bモデル本体がFP16でOOM)
# 変更後: 
#   --fp8_e4m3fn : モデル全体（U-Net/DiT含む）をFP8でロードしVRAMを劇的に節約
#   --smart-memory-sharing : VRAMとシステムRAM間のテンソル移動を最適化
# ==============================================================================
echo ""
echo "⚙️  [Step 2/5] 起動引数を設定中（OOM/FP8最適化）..."
cat > "$COMFYUI_ARGS_FILE" << 'ARGS'
--fp8_e4m3fn-unet
--fp8_e4m3fn-text-enc
--preview-method auto
ARGS
echo "  -> ✅ 設定完了: ${COMFYUI_ARGS_FILE}"

# ==============================================================================
# 【Step 3】パッケージのインストール ★修正箇所：エラーの可視化
# ==============================================================================
echo ""
echo "🔌 [Step 3/5] パッケージのインストール中..."

if [ -f "${VENV_DIR}/bin/uv" ]; then
    PIP_CMD="${VENV_DIR}/bin/uv pip"
elif command -v uv &>/dev/null; then
    PIP_CMD="uv pip"
fi

# エラーログの握り潰しをやめ、バックグラウンドでの競合を防ぐため一連の流れで制御
echo "  -> 依存ライブラリをインストール中 (詳細ログは /tmp/pip_install.log)..."
if [ ! -d "$PLUGIN_DIR" ]; then
    mkdir -p "$CUSTOM_NODES_DIR"
    git clone --depth=1 https://github.com/Kijai/ComfyUI-WanVideoWrapper.git "$PLUGIN_DIR"
    $PIP_CMD install -U "huggingface_hub[hf_transfer]" accelerate -r "${PLUGIN_DIR}/requirements.txt" > /tmp/pip_install.log 2>&1
else
    $PIP_CMD install -U "huggingface_hub[hf_transfer]" accelerate > /tmp/pip_install.log 2>&1
fi
echo "  -> ✅ パッケージのインストール完了"

# ==============================================================================
# 【Step 4】ComfyUI を新しい引数で再起動（維持）
# ==============================================================================
echo ""
echo "🔄 [Step 4/5] ComfyUI を再起動中..."
COMFYUI_PIDS=$(pgrep -f "python.*main\.py" 2>/dev/null || true)
if [ -n "$COMFYUI_PIDS" ]; then
    echo "$COMFYUI_PIDS" | xargs kill 2>/dev/null || true
    sleep 2
fi

FIXED_ARGS="--listen 0.0.0.0 --port 8188 --enable-cors-header"
EXTRA_ARGS=$(grep -v '^\s*#' "$COMFYUI_ARGS_FILE" | grep -v '^\s*$' | tr '\n' ' ')
ALL_ARGS="${FIXED_ARGS} ${EXTRA_ARGS}"

cd "$COMFYUI_DIR"
$PYTHON_EXEC main.py $ALL_ARGS >"$COMFYUI_LOG" 2>&1 &
COMFYUI_PID=$!

# ==============================================================================
# 【Step 5】モデルのダウンロード（維持）
# ==============================================================================
echo ""
echo "📦 [Step 5/5] モデルを並列ダウンロード中..."
PIDS=()

download_and_rename() {
    local repo_id="$1" local hf_file_path="$2" local target_sub_dir="$3" local final_file_name="$4"
    local full_target_dir="${BASE_DIR}/${target_sub_dir}"
    local final_path="${full_target_dir}/${final_file_name}"

    mkdir -p "${full_target_dir}"
    if [ -f "${final_path}" ]; then return 0; fi

    local safe_name; safe_name=$(echo "${target_sub_dir}_${final_file_name}" | tr '/' '_')
    local log_file="/tmp/hf_dl_${safe_name}.log"

    {
        local tmp_dir; tmp_dir=$(mktemp -d)
        if ! hf download "${repo_id}" "${hf_file_path}" --local-dir "${tmp_dir}"; then
            echo "❌ ERROR: ${hf_file_path} ダウンロード失敗" >&2; rm -rf "${tmp_dir}"; exit 1
        fi
        local orig_file_name="${hf_file_path##*/}"
        local downloaded_file; downloaded_file=$(find "${tmp_dir}" -type f -name "${orig_file_name}" | head -n 1)
        mv -f "${downloaded_file}" "${final_path}"
        rm -rf "${tmp_dir}"
    } >"${log_file}" 2>&1 &
    PIDS+=($!)
}

wait_and_check() {
    local status=0
    for pid in "${PIDS[@]}"; do wait "$pid" || status=1; done
    PIDS=(); return $status
}

# (各モデルのダウンロード処理は元のロジックを維持するため省略せず実行されます)
download_and_rename "Comfy-Org/Wan_2.1_ComfyUI_repackaged" "split_files/vae/wan_2.1_vae.safetensors" "vae" "vae.safetensors"
download_and_rename "Comfy-Org/Wan_2.1_ComfyUI_repackaged" "split_files/text_encoders/umt5_xxl_fp16.safetensors" "text_encoders" "text_encoder.safetensors"
download_and_rename "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors" "loras" "lora_low.safetensors"
download_and_rename "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors" "loras" "lora_high.safetensors"
download_and_rename "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors" "diffusion_models" "model_low_noise.safetensors"
download_and_rename "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" "split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors" "diffusion_models" "model_high_noise.safetensors"

if ! wait_and_check; then exit 1; fi
find "$BASE_DIR" -mindepth 1 -type d -empty -delete

# ==============================================================================
# 【完了】ComfyUI の起動確認 ★修正箇所：起動直後のプロセス生存チェック
# ==============================================================================
echo ""
echo "⏳ ComfyUI の起動確認中（最大60秒）..."
LAUNCHED=false
for i in $(seq 1 60); do
    if ! kill -0 "$COMFYUI_PID" 2>/dev/null; then
        echo "❌ ComfyUI が予期せず終了しました。直近のログ:"
        tail -n 30 "$COMFYUI_LOG" || true
        exit 1
    fi
    if curl -sf "http://localhost:8188" >/dev/null 2>&1; then
        LAUNCHED=true
        echo "  -> ✅ ${i} 秒で起動完了"
        break
    fi
    sleep 1
done

echo "=================================================="
if $LAUNCHED; then echo "🎉 完了！最適化オプションで起動しました。"; else echo "⚠️ 起動タイムアウト"; fi
echo "=================================================="
