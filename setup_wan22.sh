#!/bin/bash
set -euo pipefail

# ==============================================================================
# 【基本設定】
# テンプレート: ComfyUI - CUDA 12.8 (runpod-workers/comfyui-base)
#
# 【使い方】
# ComfyUIが起動してブラウザでアクセスできる状態になってから
# JupyterLab (ポート8888) のターミナルで実行してください:
#   bash /tmp/setup_wan22.sh
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
    echo "   ComfyUI の初回セットアップが完了しているか確認してください。"
    exit 1
fi

export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_XET_HIGH_PERFORMANCE=1

echo "=================================================="
echo "🚀 Wan 2.2 セットアップスクリプト"
echo "=================================================="
echo "Python: ${PYTHON_EXEC}"
echo "ComfyUI: ${COMFYUI_DIR}"
echo ""

# ==============================================================================
# 【Step 1】ComfyUI-Manager の起動時チェックを無効化
# ------------------------------------------------------------------------------
# ここで設定を書き込んでも、テンプレートが次回起動時にComfyUIごとコピーし直す
# ためリセットされる。そのため毎回このスクリプトで上書きする必要がある。
#
# Manager V3.40 で効果が確認されているキー:
#   network_mode = local          → GitHub外部Fetchをスキップ（publicがデフォルト）
#   skip_update_check = true      → カスタムノードの更新確認をスキップ
#   update_check = none           → Manager自身の更新確認を無効化
#   fetch_custom_node_list = false → FETCH ComfyRegistry Data（3分）を無効化
#   skip_migration = true         → DBマイグレーション確認をスキップ
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

echo "  -> ✅ 書き込み完了: ${MANAGER_CONFIG}"
cat "$MANAGER_CONFIG" | sed 's/^/     /'

# ==============================================================================
# 【Step 2】起動引数の設定
# ------------------------------------------------------------------------------
# テンプレートはcomfyui_args.txtを読む前に
# "--listen 0.0.0.0 --port 8188 --enable-cors-header" を固定で付加する。
# args.txtにはそれ以外の引数のみ書く（重複防止）。
#
# 非互換オプション（このテンプレートのPyTorchビルドでクラッシュする）:
#   --fast     → torch._strobelight が存在しない
#   --gpu-only → 同様にクラッシュ
# ==============================================================================
echo ""
echo "⚙️  [Step 2/5] 起動引数を設定中..."
cat > "$COMFYUI_ARGS_FILE" << 'ARGS'
--fp8_e4m3fn-text-enc
--preview-method auto
ARGS
echo "  -> ✅ 設定完了: ${COMFYUI_ARGS_FILE}"
cat "$COMFYUI_ARGS_FILE" | sed 's/^/     /'

# ==============================================================================
# 【Step 3】パッケージのインストール
# ==============================================================================
echo ""
echo "🔌 [Step 3/5] パッケージのインストール中..."

# uv の優先使用
if [ -f "${VENV_DIR}/bin/uv" ]; then
    PIP_CMD="${VENV_DIR}/bin/uv pip"
elif command -v uv &>/dev/null; then
    PIP_CMD="uv pip"
fi
echo "  -> パッケージマネージャー: ${PIP_CMD}"

{ $PIP_CMD install -U "huggingface_hub[hf_transfer]" >/dev/null 2>&1; } &
PIP_PID_HF=$!

if [ ! -d "$PLUGIN_DIR" ]; then
    echo "  -> WanVideoWrapper を新規インストール中..."
    mkdir -p "$CUSTOM_NODES_DIR"
    git clone --depth=1 https://github.com/Kijai/ComfyUI-WanVideoWrapper.git "$PLUGIN_DIR"
    { $PIP_CMD install -r "${PLUGIN_DIR}/requirements.txt" accelerate >/dev/null 2>&1; } &
else
    echo "  ⏭️  WanVideoWrapper は導入済みです。"
    { $PIP_CMD install accelerate >/dev/null 2>&1; } &
fi
PIP_PID_PLUGIN=$!

wait "$PIP_PID_HF"     || echo "⚠️  huggingface_hub のインストールで警告が発生しました。"
wait "$PIP_PID_PLUGIN" || echo "⚠️  plugin依存ライブラリのインストールで警告が発生しました。"
echo "  -> ✅ パッケージのインストール完了"

# ==============================================================================
# 【Step 4】ComfyUI を新しい引数で再起動
# ==============================================================================
echo ""
echo "🔄 [Step 4/5] ComfyUI を再起動中..."

# 既存プロセスを停止
COMFYUI_PIDS=$(pgrep -f "python.*main\.py" 2>/dev/null || true)
if [ -n "$COMFYUI_PIDS" ]; then
    echo "  -> 既存プロセス (PID: ${COMFYUI_PIDS}) を停止中..."
    echo "$COMFYUI_PIDS" | xargs kill 2>/dev/null || true
    for i in $(seq 1 10); do
        STILL=$(pgrep -f "python.*main\.py" 2>/dev/null || true)
        [ -z "$STILL" ] && break
        [ "$i" -eq 10 ] && echo "$STILL" | xargs kill -9 2>/dev/null || true
        sleep 1
    done
fi

# ポート解放
IS_BUSY=false
if command -v fuser &>/dev/null; then
    fuser 8188/tcp &>/dev/null && IS_BUSY=true || true
fi
if [ "$IS_BUSY" = true ]; then
    fuser -k 8188/tcp >/dev/null 2>&1 || true
    sleep 1
fi

# 起動
FIXED_ARGS="--listen 0.0.0.0 --port 8188 --enable-cors-header"
EXTRA_ARGS=$(grep -v '^\s*#' "$COMFYUI_ARGS_FILE" | grep -v '^\s*$' | tr '\n' ' ')
ALL_ARGS="${FIXED_ARGS} ${EXTRA_ARGS}"
echo "  -> 起動引数: ${ALL_ARGS}"

cd "$COMFYUI_DIR"
# shellcheck disable=SC2086
$PYTHON_EXEC main.py $ALL_ARGS >"$COMFYUI_LOG" 2>&1 &
COMFYUI_PID=$!
echo "  -> ComfyUI PID: ${COMFYUI_PID}"

# ==============================================================================
# 【Step 5】モデルのダウンロード（ComfyUI起動と並走）
# ==============================================================================
echo ""
echo "📦 [Step 5/5] モデルを並列ダウンロード中（ComfyUIの起動と並走）..."

PIDS=()

download_and_rename() {
    local repo_id="$1"
    local hf_file_path="$2"
    local target_sub_dir="$3"
    local final_file_name="$4"
    local full_target_dir="${BASE_DIR}/${target_sub_dir}"
    local final_path="${full_target_dir}/${final_file_name}"

    mkdir -p "${full_target_dir}"
    if [ -f "${final_path}" ]; then
        echo "  ⏭️  スキップ（配置済み）: [${target_sub_dir}] ${final_file_name}"
        return 0
    fi
    echo "  ▶️  ダウンロード開始: [${target_sub_dir}] ${final_file_name}"

    local safe_name
    safe_name=$(echo "${target_sub_dir}_${final_file_name}" | tr '/' '_')
    local log_file="/tmp/hf_dl_${safe_name}.log"

    {
        local tmp_dir
        tmp_dir=$(mktemp -d)
        if ! huggingface-cli download "${repo_id}" "${hf_file_path}" --local-dir "${tmp_dir}"; then
            echo "❌ ERROR: ${hf_file_path} のダウンロードに失敗" >&2
            rm -rf "${tmp_dir}"; exit 1
        fi
        local orig_file_name="${hf_file_path##*/}"
        local downloaded_file
        downloaded_file=$(find "${tmp_dir}" -type f -name "${orig_file_name}" | head -n 1)
        if [ -z "$downloaded_file" ]; then
            echo "❌ ERROR: ダウンロードファイルが見つかりません: ${orig_file_name}" >&2
            rm -rf "${tmp_dir}"; exit 1
        fi
        mv -f "${downloaded_file}" "${final_path}"
        rm -rf "${tmp_dir}"
        echo "  ✨ 完了: [${target_sub_dir}] ${final_file_name}"
    } >"${log_file}" 2>&1 &

    PIDS+=($!)
}

wait_and_check() {
    local status=0
    for pid in "${PIDS[@]}"; do
        wait "$pid" || status=1
    done
    PIDS=()
    return $status
}

download_and_rename "Comfy-Org/Wan_2.1_ComfyUI_repackaged" \
    "split_files/vae/wan_2.1_vae.safetensors" "vae" "vae.safetensors"

download_and_rename "Comfy-Org/Wan_2.1_ComfyUI_repackaged" \
    "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" \
    "text_encoders" "text_encoder.safetensors"

download_and_rename "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" \
    "split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors" \
    "loras" "lora_low.safetensors"

download_and_rename "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" \
    "split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors" \
    "loras" "lora_high.safetensors"

download_and_rename "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" \
    "split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors" \
    "diffusion_models" "model_low_noise.safetensors"

download_and_rename "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" \
    "split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors" \
    "diffusion_models" "model_high_noise.safetensors"

if ! wait_and_check; then
    echo ""
    echo "❌ ダウンロードエラーが発生しました。"
    echo "   詳細: /tmp/hf_dl_*.log を確認してください。"
    exit 1
fi

find "$BASE_DIR" -mindepth 1 -type d -empty -delete

# ==============================================================================
# 【完了】ComfyUI の起動確認
# ==============================================================================
echo ""
echo "⏳ ComfyUI の起動確認中（最大60秒）..."
LAUNCHED=false
for i in $(seq 1 60); do
    if ! kill -0 "$COMFYUI_PID" 2>/dev/null; then
        echo "❌ ComfyUI が予期せず終了しました。ログ:"
        tail -20 "$COMFYUI_LOG" || true
        exit 1
    fi
    if curl -sf "http://localhost:8188" >/dev/null 2>&1; then
        LAUNCHED=true
        echo "  -> ✅ ${i} 秒で起動完了"
        break
    fi
    sleep 1
done

echo ""
echo "=================================================="
if $LAUNCHED; then
    echo "🎉 完了！"
    echo ""
    echo "✅ モデル配置先:"
    find "$BASE_DIR" -name "*.safetensors" | sort | sed 's|'"$BASE_DIR"'/||' | sed 's/^/   /'
    echo ""
    echo "✅ 起動引数: ${ALL_ARGS}"
    echo ""
    echo "⚠️  【重要】次回Pod起動時の手順:"
    echo "   ComfyUIが起動したら、再度このスクリプトを実行してください。"
    echo "   テンプレートが毎回ComfyUIをリセットするため、"
    echo "   config.iniとargs.txtの設定は毎回上書きが必要です。"
    echo "   モデルは /workspace に永続保存されるため再DLは不要です。"
else
    echo "⚠️  ComfyUI の起動確認がタイムアウトしました。"
    echo "   ログ: ${COMFYUI_LOG}"
fi
echo "=================================================="
