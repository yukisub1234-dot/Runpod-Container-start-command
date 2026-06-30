# システム全体のアップデートと aria2 のインストール（初回のみ、パスワード不要）
apt-get update && apt-get install -y aria2

# Pythonスクリプトの生成
cat << 'EOF' > download_all.py
import os
import sys
import subprocess

# ====================================================================
# 1. 共通設定（APIトークンを入力してください）
# ====================================================================
CIVITAI_TOKEN = os.environ.get("civitai_token", "")
HF_TOKEN = os.environ.get("HF_TOKEN", "")

COMFYUI_ROOT = "/workspace/ComfyUI"

# トークンが取得できているか簡易チェック
if not CIVITAI_TOKEN:
    print("ℹ️ Civitai トークンは環境変数から検出されませんでした（空のまま続行します）")
if not HF_TOKEN:
    print("ℹ️ Hugging Face トークンは環境変数から検出されませんでした（空のまま続行します）")

COMFYUI_ROOT = "/workspace/ComfyUI"

# ====================================================================
# 2. ダウンロードしたいファイルのリスト
#    - source    : "civitai" または "hf"
#    - target    : Civitaiは「Version ID」、HFは「リポジトリ名」
#    - file      : Civitaiは「保存名」、HFは「リポジトリ上の正確なファイル名」
#    - path      : 保存先フォルダのパス
# ====================================================================
DOWNLOAD_LIST = [
    {
        "source": "civitai",
        "target": "123456", 
        "file": "wan22_style_lora.safetensors",
        "path": f"{COMFYUI_ROOT}/models/loras"
    },
    {
        "source": "hf",
        "target": "Kijai/WanVideo_comfy",
        "file": "Wan2.1-Diffusion-14B-Text2Video-720P_quant2.sft",
        "path": f"{COMFYUI_ROOT}/models/checkpoints",
    },
    # 必要に応じて、以下に辞書オブジェクト（{}）を追加していけます
]

# ====================================================================
# 3. 自動判別・爆速ダウンロード処理ロジック
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
    
    os.makedirs(save_dir, exist_ok=True)
    print(f"\n🚀 スタート: [{source.upper()}] -> {filename}")

    # ----------------------------------------------------------------
    # Civitai の処理 (aria2c による16並列爆速ダウンロード)
    # ----------------------------------------------------------------
    if source == "civitai":
        url = f"https://civitai.com/api/download/models/{target}"
        if CIVITAI_TOKEN and CIVITAI_TOKEN != "ここに_Civitai_のAPIキーを入力":
            url += f"?token={CIVITAI_TOKEN}"
        
        cmd = [
            "aria2c", 
            "-x", "16",       # 1サーバーへの最大接続数
            "-s", "16",       # 分割ダウンロード数
            "-d", save_dir,   # 保存先ディレクトリ
            "-o", filename,   # 保存ファイル名
            url
        ]
        
        print(f"📥 実行コマンド (aria2 16並列): {' '.join(cmd)}")
        subprocess.run(cmd)

    # ----------------------------------------------------------------
    # Hugging Face の処理 (hf_transfer による並列爆速ダウンロード)
    # ----------------------------------------------------------------
    elif source == "hf":
        ensure_dependencies("hf")
        
        env = os.environ.copy()
        if HF_TOKEN and HF_TOKEN != "hf_ここに_HuggingFace_のトークンを入力":
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
