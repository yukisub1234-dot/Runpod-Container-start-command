# ComfyUI Model Downloader

RunPod上のComfyUI環境向けに、Civitai / Hugging Face からモデル(チェックポイント・LoRA・VAE・テキストエンコーダーなど)を一括ダウンロードするスクリプトです。

## 特徴

- **並列ダウンロード**: `ThreadPoolExecutor` により複数モデルを同時取得
- **SHA256検証**: ダウンロード後のファイル整合性をチェックサムで確認
- **重複ダウンロード防止**: 同一セッション内の二重処理をロックでブロック、既存ファイルは自動スキップ
- **Network Volume対応**: `/workspace` が永続ボリュームかを自動判定し、Pod再作成時の無駄な再ダウンロードを防止
- **設定の外部化**: ダウンロード対象は `models.json` で管理(コード変更不要)
- **自動リトライ**: 一時的なネットワークエラーに対して再試行

## ディレクトリ構成

```
.
├── download_all.py   # ダウンロード実行スクリプト
├── models.json        # ダウンロード対象モデルのリスト(要編集)
└── README.md
```

ダウンロードしたファイルは種類に応じて `COMFYUI_ROOT/models/` 配下の各サブディレクトリに自動配置されます。

| type          | 配置先                          |
|---------------|----------------------------------|
| `checkpoint`  | `models/checkpoints`             |
| `lora`        | `models/loras`                   |
| `vae`         | `models/vae`                     |
| `clip`        | `models/text_encoders`           |
| `diffusion`   | `models/diffusion_models`        |
| `upscale`     | `models/upscale_models`          |
| `controlnet`  | `models/controlnet`              |

## セットアップ

### 1. 環境変数の設定

RunPodのPod設定画面の **Environment Variables**、またはターミナルで以下を設定します。

```bash
export CIVITAI_TOKEN="your_civitai_api_token"
export HF_TOKEN="your_huggingface_token"
export COMFYUI_ROOT="/workspace/ComfyUI"   # 省略時のデフォルト値
```

- `CIVITAI_TOKEN`: [Civitai Account Settings](https://civitai.com/user/account) から発行
- `HF_TOKEN`: [Hugging Face Settings > Access Tokens](https://huggingface.co/settings/tokens) から発行(read権限で可)

### 2. リポジトリの取得

```bash
cd /workspace
git clone https://github.com/<your-username>/<your-repo>.git
cd <your-repo>
```

### 3. `models.json` の編集

ダウンロードしたいモデルを追記します。

```json
{
  "models": [
    {
      "source": "civitai",
      "target": "モデルID",
      "file": "任意のファイル名.safetensors",
      "type": "checkpoint",
      "sha256": ""
    },
    {
      "source": "hf",
      "target": "リポジトリ名(例: Comfy-Org/xxx)",
      "file": "リポジトリ内のファイルパス",
      "type": "vae",
      "sha256": ""
    }
  ]
}
```

| フィールド     | 必須 | 説明                                                                 |
|----------------|------|----------------------------------------------------------------------|
| `source`       | ✅   | `civitai` または `hf`                                               |
| `target`       | ✅   | CivitaiのモデルID、またはHFのリポジトリ名                            |
| `file`         | ✅   | ダウンロードするファイル名(HFの場合はリポジトリ内パス)               |
| `type`         | ✅   | 保存先ディレクトリの種類(上表参照)                                   |
| `rename_to`    | 任意 | 保存後にリネームしたい場合のファイル名                               |
| `sha256`       | 任意 | 整合性検証用のハッシュ値。モデル配布ページに記載があれば設定推奨      |
| `path`         | 任意 | `type` が未定義の場合の保存先を直接指定                              |

CivitaiのハッシュはモデルページのFile欄、HFのハッシュはファイル詳細(SHA256列)で確認できます。

## 実行方法

### ターミナルから(推奨)

```bash
python download_all.py --config models.json --workers 3
```

| オプション   | デフォルト     | 説明               |
|--------------|----------------|--------------------|
| `--config`   | `models.json`  | 設定ファイルのパス |
| `--workers`  | `3`            | 並列ダウンロード数 |

### バックグラウンド実行(大容量モデル・長時間DL向け)

JupyterLabやSSHセッションが切れてもダウンロードを継続させたい場合:

```bash
nohup python download_all.py --config models.json --workers 3 > download.log 2>&1 &
tail -f download.log   # 進捗確認(Ctrl+Cで監視終了、DLは継続)
```

### JupyterLabのノートブックセルから

```python
import os
print("CIVITAI_TOKEN:", "設定済み" if os.environ.get("CIVITAI_TOKEN") else "未設定")
print("HF_TOKEN:", "設定済み" if os.environ.get("HF_TOKEN") else "未設定")
```

```python
!python download_all.py --config models.json --workers 3
```

## 出力例

```
✅ /workspace は独立したボリューム(Network Volume想定)です。Pod再起動後もモデルは保持されます。

📋 3 件のモデルを最大 3 並列でダウンロードします

🚀 開始: [CIVITAI] (checkpoint) realistic_checkpoint.safetensors -> realistic_checkpoint.safetensors
🚀 開始: [HF] (vae) split_files/vae/wan_2.1_vae.safetensors -> wan_2.1_vae.safetensors
✅ 完了: realistic_checkpoint.safetensors
✅ 完了: wan_2.1_vae.safetensors

============================================================
📊 ダウンロード結果サマリー
============================================================
  ✅ 成功: realistic_checkpoint.safetensors
  ✅ 成功: wan_2.1_vae.safetensors
============================================================
✨ すべて正常に完了しました。
```

## トラブルシューティング

| 症状                              | 原因・対処                                                                 |
|-----------------------------------|------------------------------------------------------------------------------|
| `❌ HTMLが返却されています`        | トークンが無効/期限切れ、または非公開モデルへのアクセス権限がない            |
| `❌ ハッシュ不一致`                | モデルが更新された、またはダウンロードが破損している。再実行してみてください |
| `⚠️ Network Volumeが未接続の可能性` | `/workspace` がPersistent Volumeにマウントされているか、RunPodのPod設定を確認 |
| ダウンロードが途中で止まる          | `nohup` を使ったバックグラウンド実行に切り替える                             |

## セキュリティに関する注意

- トークンは環境変数管理とし、`models.json` やコード内にハードコードしないでください
- `.gitignore` に以下を含めることを推奨します

```
*.safetensors
*.ckpt
*.pt
.env
download.log
```

## ライセンス

ダウンロードするモデル自体のライセンス・利用規約は、各配布元(Civitai / Hugging Face)のページで個別にご確認ください。
