# Pythonスクリプトを確実なwget形式に書き換え
cat << 'EOF' > download_all.py
import os
import sys
import subprocess

# ====================================================================
# 1. 秘密鍵（環境変数）からトークンを自動取得
# ====================================================================
CIVITAI_TOKEN = os.environ.get("CIVITAI_TOKEN", "")
HF_TOKEN = os.environ.get("HF_TOKEN", "")

COMFYUI_ROOT = "/workspace/ComfyUI"

if not CIVITAI_TOKEN:
    print("ℹ️ Civitai トークンは環境変数から検出されませんでした")
if not HF_TOKEN:
    print("ℹ️ Hugging Face トークンは環境変数から検出されませんでした")

# ====================================================================
# 2. ダウンロードしたいファイルのリスト
# ====================================================================
DOWNLOAD_LIST = [
    {
        "source": "civitai",
        "target": "", 
        "file": "xxx_lora.safetensors",
        "path": f"{COMFYUI_ROOT}/models/loras"
    },
    {
        "source": "hf",
        "target": "Kijai/WanVideo_comfy",
        "file": "Wan2.1-Diffusion-14B-Text2Video-720P_quant2.sft",
        "path": f"{COMFYUI_ROOT}/models/checkpoints",
        "rename_to": "wan2.1_720p_q2.sft"
    },
]

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
    save_dir = item["path"].strip()
    rename_to = item.get("rename_to")
    
    os.makedirs(save_dir, exist_ok=True)
    print(f"\n🚀 スタート: [{source.upper()}] -> {filename}")

    # ----------------------------------------------------------------
    # Civitai の処理 (リダイレクト・認証に強い wget で確実に落とす)
    # ----------------------------------------------------------------
    if source == "civitai":
        url = f"https://civitai.com/api/download/models/{target}"
        if CIVITAI_TOKEN:
            url += f"?token={CIVITAI_TOKEN}"
        
        save_path = os.path.join(save_dir, filename)
        
        # リダイレクトを完全に追跡し、403を回避するwgetオプション
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
            
        # hf_transfer 高速化モードを有効化
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
        
        # ダウンロード後の自動リネーム処理
        if rename_to:
            old_path = os.path.join(save_dir, filename)
            new_path = os.path.join(save_dir, rename_to.strip())
            if os.path.exists(old_path):
                os.rename(old_path, new_path)
                print(f"🔄 ファイルをリネームしました: {filename} -> {rename_to}")
            else:
                print(f"⚠️ リネーム対象のファイルが見つかりません: {old_path}")
                
    else:
        print(f"❌ 不明なソースタイプです: {source} (civitai または hf を指定してください)")

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
