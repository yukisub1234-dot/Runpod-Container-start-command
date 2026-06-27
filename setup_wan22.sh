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
# 【仮想環境の自動検出】
# ==============================================================================
VENV_DIR="${COMFYUI_DIR}/.venv-cu128"

if [ -d "$VENV_DIR" ]; then
    export PATH="${VENV_DIR}/bin:$PATH"
    PYTHON_EXEC="${VENV_DIR}/bin/python"
    PIP_CMD="${VENV_DIR}/bin/pip"
else
    PYTHON_EXEC="python3"
    PIP_CMD="pip3"
fi

export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_XET_HIGH_PERFORMANCE=1

# ==============================================================================
# 【初回起動ガード】
# テンプレートは初回起動時に ComfyUI を /workspace へコピーする（約50秒）。
# その完了を待ってからスクリプトを進める。
# ==============================================================================
echo "⏳ [Guard] ComfyUI ディレクトリの準備を確認中..."
for i in $(seq 1 60); do
    if [ -f "${COMFYUI_DIR}/main.py" ]; then
        echo "  -> ✅ ComfyUI ディレクトリ確認完了（${i} 回目のチェック）"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "❌ ComfyUI ディレクトリが見つかりません: ${COMFYUI_DIR}"
        exit 1
    fi
    sleep 5
done

# venv が初回起動後に生成された場合は再検出
if [ ! -d "$VENV_DIR" ] && [ -d "${COMFYUI_DIR}/.venv-cu128" ]; then
    VENV_DIR="${COMFYUI_DIR}/.venv-cu128"
    export PATH="${VENV_DIR}/bin:$PATH"
    PYTHON_EXEC="${VENV_DIR}/bin/python"
    PIP_CMD="${VENV_DIR}/bin/pip"
fi

# ==============================================================================
# 【起動引数の設定】
# ------------------------------------------------------------------------------
# ⚠️ 重複引数バグの修正:
#   このテンプレートの起動スクリプトは comfyui_args.txt の内容を読み込む前に
#   "--listen 0.0.0.0 --port 8188 --enable-cors-header" をハードコードで付加する。
#   そのため args.txt にこれらを書くと二重になる。
#   → args.txt にはテンプレートが付加しない引数だけを記載する。
#
# ⚠️ --fast 削除:
#   このテンプレートの PyTorch ビルドには torch._strobelight が含まれておらず、
#   --fast を指定すると "ModuleNotFoundError: No module named 'torch._strobelight'"
#   でクラッシュする。
#
# RTX 4090（24GB）向け有効な最適化:
#   --fp8_e4m3fn-text-enc : Text Encoder を fp8 で動かしVRAMを節約
#   --preview-method auto : プレビュー生成を自動最適化
#
# ⚠️ このテンプレートのPyTorchビルドと非互換のオプション（使用禁止）:
#   --fast     → torch._strobelight が存在せずクラッシュ
#   --gpu-only → 同様に torch._strobelight を間接的に要求しクラッシュ
# ==============================================================================
echo "⚙️  [Args] comfyui_args.txt を設定中..."

# テンプレートが付加するデフォルト引数（重複を避けるため args.txt には書かない）:
#   --listen 0.0.0.0 --port 8188 --enable-cors-header
cat > "$COMFYUI_ARGS_FILE" << 'ARGS'
--fp8_e4m3fn-text-enc
--preview-method auto
ARGS

echo "  -> ✅ 設定完了: ${COMFYUI_ARGS_FILE}"
echo "  -> 内容（テンプレートの固定引数と結合されて起動）:"
cat "$COMFYUI_ARGS_FILE" | sed 's/^/     /'

# ==============================================================================
# 🔌 【プラグイン自動導入】pip の並列インストール
# ==============================================================================
echo ""
echo "🔌 [Setup] プラグイン・環境のチェックを開始します..."

# uv の優先使用
if [ -f "${VENV_DIR}/bin/uv" ]; then
    PIP_CMD="${VENV_DIR}/bin/uv pip"
elif command -v uv &>/dev/null; then
    PIP_CMD="uv pip"
else
    echo "  -> ⚡ 'uv' をインストール中..."
    $PYTHON_EXEC -m pip install uv >/dev/null 2>&1 || true
    if [ -f "${VENV_DIR}/bin/uv" ]; then
        PIP_CMD="${VENV_DIR}/bin/uv pip"
    elif command -v uv &>/dev/null; then
        PIP_CMD="uv pip"
    fi
fi

echo "  -> 使用するパッケージマネージャー: ${PIP_CMD}"

# hf_transfer を並列インストール
{
    $PIP_CMD install -U "huggingface_hub[hf_transfer]" >/dev/null 2>&1
} &
PIP_PID_HF=$!

# WanVideoWrapper の導入
if [ ! -d "$PLUGIN_DIR" ]; then
    echo "  -> 🚨 WanVideoWrapper を新規ダウンロード中..."
    mkdir -p "$CUSTOM_NODES_DIR"
    git clone --depth=1 https://github.com/Kijai/ComfyUI-WanVideoWrapper.git "$PLUGIN_DIR"
    {
        $PIP_CMD install -r "${PLUGIN_DIR}/requirements.txt" accelerate >/dev/null 2>&1
    } &
    PIP_PID_PLUGIN=$!
else
    echo "  ⏭️  WanVideoWrapper は導入済みです。"
    {
        $PIP_CMD install accelerate >/dev/null 2>&1
    } &
    PIP_PID_PLUGIN=$!
fi

wait "$PIP_PID_HF"     || echo "⚠️  huggingface_hub のインストールで警告が発生しました。"
wait "$PIP_PID_PLUGIN" || echo "⚠️  plugin依存ライブラリのインストールで警告が発生しました。"
echo "  ✨ パッケージのセットアップ完了"

# ==============================================================================
# 【高速化】ComfyUI-Manager の起動時チェックを無効化
# ------------------------------------------------------------------------------
# デフォルトでは Manager が起動のたびにネットワークアクセスして
# 依存関係・アップデートの確認を行うため、毎回約3分のロスが発生する。
#
# ログで確認した実際のキー名:
#   network_mode  -> "public" がデフォルト。"offline" に変更で外部通信をスキップ
#
# 重要: Manager は起動時に config.ini を読むため、
#       必ず ComfyUI の再起動よりも前に書き込む必要がある。
#       またファイルを「上書き」ではなく「完全置換」することで、
#       古い設定が残って混在するリスクを排除する。
# ==============================================================================
echo ""
echo "⚙️  [Manager] 起動時チェックを無効化中..."
MANAGER_CONFIG_DIR="${COMFYUI_DIR}/user/__manager"
MANAGER_CONFIG="${MANAGER_CONFIG_DIR}/config.ini"
mkdir -p "$MANAGER_CONFIG_DIR"

# Manager V3.40 のログ解析結果に基づく設定:
#   network_mode = local  : "public"(デフォルト) -> "local" でGitHub外部Fetchをスキップ
#                           "offline" は期待通り動作しないケースあり
#   skip_update_check = true  : カスタムノードの更新確認をスキップ
#   update_check = none       : Manager自身の更新確認を無効化
#   fetch_custom_node_list = false : FETCH ComfyRegistry Data（156件）を無効化
#   skip_migration = true     : DBマイグレーション確認をスキップ
cat > "$MANAGER_CONFIG" << 'MANAGER_CONF'
[default]
skip_update_check = true
update_check = none
network_mode = local
fetch_custom_node_list = false
skip_migration = true
MANAGER_CONF

echo "  -> ✅ config.ini を書き込みました: ${MANAGER_CONFIG}"
echo "  -> 内容:"
cat "$MANAGER_CONFIG" | sed 's/^/     /'


# ==============================================================================
# 【ComfyUI の再起動】新しい引数を反映
# ==============================================================================
echo ""
echo "🔄 [Restart] ComfyUI を最適化引数で再起動します..."

COMFYUI_PIDS=$(pgrep -f "python.*main\.py" 2>/dev/null || true)
if [ -n "$COMFYUI_PIDS" ]; then
    echo "  -> 既存プロセス (PID: ${COMFYUI_PIDS}) を停止中..."
    echo "$COMFYUI_PIDS" | xargs kill 2>/dev/null || true
    for i in $(seq 1 10); do
        STILL_RUNNING=$(pgrep -f "python.*main\.py" 2>/dev/null || true)
        [ -z "$STILL_RUNNING" ] && break
        [ "$i" -eq 10 ] && echo "$STILL_RUNNING" | xargs kill -9 2>/dev/null || true
        sleep 1
    done
    echo "  -> ✅ 既存プロセスを停止しました。"
fi

IS_BUSY=false
if command -v fuser &>/dev/null; then
    fuser 8188/tcp &>/dev/null && IS_BUSY=true || true
elif command -v lsof &>/dev/null; then
    lsof -ti:8188 &>/dev/null && IS_BUSY=true || true
fi
if [ "$IS_BUSY" = true ]; then
    if command -v fuser &>/dev/null; then
        fuser -k 8188/tcp >/dev/null 2>&1 || true
    elif command -v lsof &>/dev/null; then
        lsof -ti:8188 | xargs -r kill || true
    fi
    sleep 1
fi

# テンプレートの固定引数 + args.txt の内容を結合して起動
# （テンプレートと同じ組み立て方に揃えることで二重付加を防ぐ）
FIXED_ARGS="--listen 0.0.0.0 --port 8188 --enable-cors-header"
EXTRA_ARGS=$(grep -v '^\s*#' "$COMFYUI_ARGS_FILE" | grep -v '^\s*$' | tr '\n' ' ')
ALL_ARGS="${FIXED_ARGS} ${EXTRA_ARGS}"

echo "  -> 起動引数: ${ALL_ARGS}"
cd "$COMFYUI_DIR"

# shellcheck disable=SC2086
$PYTHON_EXEC main.py $ALL_ARGS >"$COMFYUI_LOG" 2>&1 &
COMFYUI_PID=$!
echo "  -> ComfyUI を PID ${COMFYUI_PID} で起動しました。"

# ==============================================================================
# 【モデルのダウンロード】ComfyUI 起動と並走
# ==============================================================================
echo ""
echo "🚀 【Wan 2.2】全モデルを一括並列ダウンロード開始..."

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
        echo "⏭️  スキップ（配置済み）: [${target_sub_dir}] ${final_file_name}"
        return 0
    fi

    echo "▶️  並列ダウンロード開始: [${target_sub_dir}] ${final_file_name}"

    local safe_name
    safe_name=$(echo "${target_sub_dir}_${final_file_name}" | tr '/' '_')
    local log_file="/tmp/hf_dl_${safe_name}.log"

    {
        local tmp_dir
        tmp_dir=$(mktemp -d)

        if ! huggingface-cli download "${repo_id}" "${hf_file_path}" --local-dir "${tmp_dir}"; then
            echo "❌ ERROR: [${target_sub_dir}] ${hf_file_path} のダウンロードに失敗しました。" >&2
            rm -rf "${tmp_dir}"
            exit 1
        fi

        local orig_file_name="${hf_file_path##*/}"
        local downloaded_file
        downloaded_file=$(find "${tmp_dir}" -type f -name "${orig_file_name}" | head -n 1)

        if [ -z "$downloaded_file" ]; then
            echo "❌ ERROR: ダウンロード済みファイルが見つかりません: ${orig_file_name}" >&2
            rm -rf "${tmp_dir}"
            exit 1
        fi

        mv -f "${downloaded_file}" "${final_path}"
        rm -rf "${tmp_dir}"
        echo "✨ 完了＆配置済み: [${target_sub_dir}] ${final_file_name}"
    } >"${log_file}" 2>&1 &

    PIDS+=($!)
}

wait_and_check() {
    local overall_status=0
    for pid in "${PIDS[@]}"; do
        if ! wait "$pid"; then
            overall_status=1
        fi
    done
    PIDS=()
    return $overall_status
}

download_and_rename \
    "Comfy-Org/Wan_2.1_ComfyUI_repackaged" \
    "split_files/vae/wan_2.1_vae.safetensors" \
    "vae" "vae.safetensors"

download_and_rename \
    "Comfy-Org/Wan_2.1_ComfyUI_repackaged" \
    "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" \
    "text_encoders" "text_encoder.safetensors"

download_and_rename \
    "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" \
    "split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors" \
    "loras" "lora_low.safetensors"

download_and_rename \
    "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" \
    "split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors" \
    "loras" "lora_high.safetensors"

download_and_rename \
    "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" \
    "split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors" \
    "diffusion_models" "model_low_noise.safetensors"

download_and_rename \
    "Comfy-Org/Wan_2.2_ComfyUI_Repackaged" \
    "split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors" \
    "diffusion_models" "model_high_noise.safetensors"

if ! wait_and_check; then
    echo "❌ ダウンロードエラーが発生しました。詳細は /tmp/hf_dl_*.log を確認してください。"
    exit 1
fi

echo "✅ 全モデルのダウンロード完了"
find "$BASE_DIR" -mindepth 1 -type d -empty -delete

# ==============================================================================
# 【起動確認】ヘルスチェック（最大60秒）
# ==============================================================================
echo ""
echo "  -> ComfyUI の起動確認中（最大60秒）..."
LAUNCHED=false
for i in $(seq 1 60); do
    if ! kill -0 "$COMFYUI_PID" 2>/dev/null; then
        echo "❌ ComfyUI プロセスが予期せず終了しました。"
        echo "   ログを確認してください: ${COMFYUI_LOG}"
        echo "   --- 末尾20行 ---"
        tail -20 "$COMFYUI_LOG" || true
        exit 1
    fi
    if curl -sf "http://localhost:8188" >/dev/null 2>&1; then
        LAUNCHED=true
        echo "  -> ✅ ComfyUI が ${i} 秒で起動完了しました。"
        break
    fi
    sleep 1
done

echo ""
echo "============================================================"
if $LAUNCHED; then
    echo "🎉 [COMPLETE] 全モデルの配置 ＆ ComfyUI の起動が完了しました！"
    echo "💡 RunPodの接続用URLからそのままアクセス可能です。"
    echo ""
    echo "📋 適用済み起動引数:"
    echo "   ${ALL_ARGS}"
else
    echo "⚠️  [WARNING] ComfyUI の起動確認がタイムアウトしました。"
    echo "   ログを確認してください: ${COMFYUI_LOG}"
fi
echo "============================================================"
