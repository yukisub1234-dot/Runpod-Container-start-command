# Pythonスクリプトを確実なwget形式に書き換え
cat << 'EOF' > download_all.py
import os
import sys
import subprocess



# ====================================================================
# 1. ダウンロードしたいファイルのリスト
# ====================================================================
DOWNLOAD_LIST = [
    {
        "source": "civitai",
        "target": "2342652",  # 例: CivitaiのバージョンID
        "file": "paizuri_lora.safetensors",
        "type": "lora",
        "rename_to": "paizuri" # 保存名
    },{
        "source": "civitai",
        "target": "2504591",  # 例: CivitaiのバージョンID
        "file": "onani_lora.safetensors",
        "type": "lora",
        "rename_to": "onani" # 保存名
    },{
        "source": "civitai",
        "target": "2235288",  # 例: CivitaiのバージョンID
        "file": "blowjob_lora.safetensors",
        "type": "lora",
        "rename_to": "blowjob" # 保存名
    },{
        "source": "civitai",
        "target": "1602715",  # 例: CivitaiのバージョンID
        "file": "bukkake_lora.safetensors",
        "type": "lora",
        "rename_to": "bukkake" # 保存名
    },{
        "source": "civitai",
        "target": "2210320",  # 例: CivitaiのバージョンID
        "file": "paimomi_lora.safetensors",
        "type": "lora",
        "rename_to": "paimomi" # 保存名
    },
    {
        "source": "hf",
        "target": "NSFW-API/NSFW-Wan-UMT5-XXL",
        "file": "nsfw_wan_umt5-xxl_fp8_scaled.safetensors",
        "type": "clip",
        "rename_to": "nsfw_wan_umt5-xxl_fp8_scaled"
    },
]


# ====================================================================
# 2. 秘密鍵（環境変数）からトークンを自動取得
# ====================================================================
CIVITAI_TOKEN = os.environ.get("CIVITAI_TOKEN", "")
HF_TOKEN = os.environ.get("HF_TOKEN", "")

COMFYUI_ROOT = "/workspace/ComfyUI"

if not CIVITAI_TOKEN:
    print("ℹ️ Civitai トークンは環境変数から検出されませんでした")
if not HF_TOKEN:
    print("ℹ️ Hugging Face トークンは環境変数から検出されませんでした")

# ====================================================================
# 種類に応じたディレクトリの定義（マッピング）
# ====================================================================
DIR_MAPPING = {
    "diffusion": f"{COMFYUI_ROOT}/models/diffusion_models", # Wanのメインモデル(SFT)用
    "checkpoint": f"{COMFYUI_ROOT}/models/checkpoints",
    "lora": f"{COMFYUI_ROOT}/models/loras",
    "clip": f"{COMFYUI_ROOT}/models/text_encoders",         # UMTextEncoder や CLIP 用
    "vae": f"{COMFYUI_ROOT}/models/vae",                   # VAE用
}

# ====================================================================
# 3. 自動判別・ダウンロード処理ロジック
# ====================================================================
def ensure_dependencies(source):
    if source == "hf":
        try:
            import huggingface_hub
            import hf_transfer
        except ImportError:
            print("📦 Hugging Face 用の高速化ライブラリをインストール中...")
            subprocess.run([sys.executable, "-m", "pip", "install", "-U", "huggingface_hub[cli]", "hf_transfer"], check=True)

def download_item(item):
    source = item["source"].lower().strip()
    target = item["target"].strip()
    filename = item["file"].strip()
    rename_to = item.get("rename_to")
    
    # 種類の判定と保存先ディレクトリの自動決定
    file_type = item.get("type", "").lower().strip()
    if file_type in DIR_MAPPING:
        save_dir = DIR_MAPPING[file_type]
    else:
        save_dir = item.get("path", f"{COMFYUI_ROOT}/models/checkpoints").strip()
        print(f"⚠️ 種類 '{file_type}' が定義されていないため、デフォルトパスを使用します: {save_dir}")

    os.makedirs(save_dir, exist_ok=True)
    print(f"\n🚀 スタート: [{source.upper()}] ({file_type}) -> {filename}")

    # ----------------------------------------------------------------
    # Civitai の処理 (リダイレクト・認証に強い wget で確実に落とす)
    # ----------------------------------------------------------------
    if source == "civitai":
        url = f"https://civitai.com/api/download/models/{target}"
        if CIVITAI_TOKEN:
            url += f"?token={CIVITAI_TOKEN}"
        
        save_path = os.path.join(save_dir, filename)
        
        cmd = [
            "wget", 
            "--no-check-certificate",
            "--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64)", 
            "-O", save_path, 
            url
        ]
        
        print(f"📥 実行コマンド (wget 安定モード): {' '.join(cmd)}")
        subprocess.run(cmd)

    # ----------------------------------------------------------------
    # Hugging Face の処理 (hf_transfer による並列爆速ダウンロード)
    # ----------------------------------------------------------------
    elif source == "hf":
        ensure_dependencies("hf")
        
        env = os.environ.copy()
        if HF_TOKEN:
            env["HF_TOKEN"] = HF_TOKEN
            
        env["HF_HUB_ENABLE_HF_TRANSFER"] = "1"
            
        cmd = [
            "huggingface-cli", "download",
            target,
            filename,
            "--local-dir", save_dir,
            "--local-dir-use-symlinks", "False"
        ]
        
        print(f"📥 実行コマンド (hf_transfer モード): {' '.join(cmd)}")
        subprocess.run(cmd, env=env)
                
    else:
        print(f"❌ 不明なソースタイプです: {source} (civitai または hf を指定してください)")
        return

    # ----------------------------------------------------------------
    # [共通処理] ダウンロード後の自動リネーム（Civitai / HF 両対応）
    # ----------------------------------------------------------------
    if rename_to:
        old_path = os.path.join(save_dir, filename)
        new_path = os.path.join(save_dir, rename_to.strip())
        if os.path.exists(old_path):
            os.rename(old_path, new_path)
            print(f"🔄 ファイルをリネームしました: {filename} -> {rename_to}")
        else:
            print(f"⚠️ リネーム対象のファイルが見つかりません: {old_path}")

if __name__ == "__main__":
    for item in DOWNLOAD_LIST:
        try:
            download_item(item)
        except Exception as e:
            print(f"💥 ダウンロード中にエラーが発生しました ({item.get('file')}): {e}")
    print("\n✨ すべてのファイルのダウンロード・最適化処理が完了しました。")
EOF

# スクリプトの実行
python download_all.py
