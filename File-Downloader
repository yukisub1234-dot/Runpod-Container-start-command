#!/usr/bin/env python3
"""
ComfyUI モデル一括ダウンローダー(RunPod想定)

機能:
  - Civitai / Hugging Face からのダウンロード
  - SHA256チェックサム検証(整合性 & 重複防止)
  - ThreadPoolExecutorによる並列ダウンロード
  - RunPod Network Volume 検出と活用(再ダウンロード防止)
  - models.json によるダウンロードリストの外部化
  - 同一ファイルへの同時アクセス防止(ロック)

使い方:
  export CIVITAI_TOKEN="..."
  export HF_TOKEN="..."
  python download_all.py --config models.json --workers 3
"""

import os
import sys
import json
import time
import hashlib
import argparse
import threading
import subprocess
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

# ====================================================================
# 環境設定
# ====================================================================
CIVITAI_TOKEN = os.environ.get("CIVITAI_TOKEN", "")
HF_TOKEN = os.environ.get("HF_TOKEN", "")
COMFYUI_ROOT = os.environ.get("COMFYUI_ROOT", "/workspace/ComfyUI")

DIR_MAPPING = {
    "diffusion": f"{COMFYUI_ROOT}/models/diffusion_models",
    "checkpoint": f"{COMFYUI_ROOT}/models/checkpoints",
    "lora": f"{COMFYUI_ROOT}/models/loras",
    "clip": f"{COMFYUI_ROOT}/models/text_encoders",
    "vae": f"{COMFYUI_ROOT}/models/vae",
    "upscale": f"{COMFYUI_ROOT}/models/upscale_models",
    "controlnet": f"{COMFYUI_ROOT}/models/controlnet",
}

MIN_VALID_SIZE_BYTES = 1024 * 1024  # 1MB未満は失敗扱い
HASH_CHUNK_SIZE = 8 * 1024 * 1024   # 8MBずつ読んでハッシュ計算(メモリ節約)

# 重複防止: 同一の保存先パスに対して同時にDLが走らないようにするロック
_path_locks: dict[str, threading.Lock] = {}
_path_locks_guard = threading.Lock()

# 既にこの実行中に処理済み(成功/スキップ)になった最終パスの集合
_completed_paths: set[str] = set()
_completed_guard = threading.Lock()

print_lock = threading.Lock()


def log(msg: str):
    with print_lock:
        print(msg, flush=True)


# ====================================================================
# Network Volume 検出
# ====================================================================
def check_network_volume():
    """/workspace がRunPodのNetwork Volume(永続ボリューム)かどうかを簡易判定する"""
    workspace = Path("/workspace")
    if not workspace.exists():
        log("⚠️ /workspace が存在しません。COMFYUI_ROOT の設定を確認してください。")
        return False

    try:
        # マウントポイントかどうかは st_dev の比較で簡易判定
        is_mount = workspace.stat().st_dev != Path("/").stat().st_dev
    except OSError:
        is_mount = False

    if is_mount:
        log("✅ /workspace は独立したボリューム(Network Volume想定)です。"
            "Pod再起動後もモデルは保持されます。")
    else:
        log("⚠️ /workspace はルートディスクと同一デバイスです。"
            "Network Volumeが未接続の場合、Pod削除時にモデルが消える可能性があります。")
    return is_mount


# ====================================================================
# ハッシュ計算 & 検証
# ====================================================================
def compute_sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(HASH_CHUNK_SIZE):
            h.update(chunk)
    return h.hexdigest()


def validate_file(path: str, expected_sha256: str = "") -> bool:
    if not os.path.exists(path):
        return False

    size = os.path.getsize(path)
    if size < MIN_VALID_SIZE_BYTES:
        log(f"⚠️ ファイルサイズが不審に小さいです ({size} bytes): {path}")
        return False

    with open(path, "rb") as f:
        head = f.read(15)
        if head.startswith(b"<!DOCTYPE") or head.startswith(b"<html"):
            log(f"⚠️ HTMLが返却されています(認証エラー等の可能性): {path}")
            return False

    if expected_sha256:
        log(f"🔍 SHA256検証中: {os.path.basename(path)}")
        actual = compute_sha256(path)
        if actual.lower() != expected_sha256.lower():
            log(f"❌ ハッシュ不一致: {os.path.basename(path)}\n"
                f"   期待値: {expected_sha256}\n   実際値: {actual}")
            return False
        log(f"✅ ハッシュ一致: {os.path.basename(path)}")

    return True


# ====================================================================
# 重複防止ロック
# ====================================================================
def get_lock_for(path: str) -> threading.Lock:
    with _path_locks_guard:
        if path not in _path_locks:
            _path_locks[path] = threading.Lock()
        return _path_locks[path]


def already_completed(path: str) -> bool:
    with _completed_guard:
        return path in _completed_paths


def mark_completed(path: str):
    with _completed_guard:
        _completed_paths.add(path)


# ====================================================================
# 依存関係
# ====================================================================
def ensure_hf_deps():
    try:
        import huggingface_hub  # noqa
    except ImportError:
        log("📦 huggingface_hub をインストール中...")
        subprocess.run(
            [sys.executable, "-m", "pip", "install", "-U", "huggingface_hub[cli]", "hf_transfer"],
            check=True,
        )


# ====================================================================
# ダウンローダー本体
# ====================================================================
def download_civitai(target, filename, save_path, retries=3) -> bool:
    url = f"https://civitai.com/api/download/models/{target}"
    headers = ["--header", f"Authorization: Bearer {CIVITAI_TOKEN}"] if CIVITAI_TOKEN else []

    for attempt in range(1, retries + 1):
        cmd = [
            "wget",
            "--no-check-certificate",
            "--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
            *headers,
            "-O", save_path,
            url,
        ]
        log(f"📥 [Civitai 試行 {attempt}/{retries}] {filename}")
        result = subprocess.run(cmd, capture_output=True)

        if result.returncode == 0 and os.path.exists(save_path):
            return True

        log(f"❌ 失敗 (returncode={result.returncode}): {filename}")
        if os.path.exists(save_path):
            os.remove(save_path)
        time.sleep(3)

    return False


def download_hf(target, filename, save_dir) -> str | None:
    ensure_hf_deps()
    from huggingface_hub import hf_hub_download

    try:
        path = hf_hub_download(
            repo_id=target,
            filename=filename,
            local_dir=save_dir,
            token=HF_TOKEN or None,
        )
        return path
    except Exception as e:
        log(f"❌ HFダウンロード失敗 ({filename}): {e}")
        return None


# ====================================================================
# 1アイテム処理(スレッドで実行される単位)
# ====================================================================
def process_item(item: dict) -> dict:
    source = item["source"].lower().strip()
    target = item["target"].strip()
    filename = item["file"].strip()
    rename_to = item.get("rename_to")
    file_type = item.get("type", "").lower().strip()
    expected_sha256 = item.get("sha256", "").strip()

    save_dir = DIR_MAPPING.get(file_type, item.get("path", f"{COMFYUI_ROOT}/models/checkpoints"))
    os.makedirs(save_dir, exist_ok=True)

    final_name = rename_to if rename_to else os.path.basename(filename)
    final_path = os.path.join(save_dir, final_name)

    # --- 重複防止: 同じ最終パスへの二重処理をブロック ---
    lock = get_lock_for(final_path)
    with lock:
        if already_completed(final_path):
            log(f"⏭️ 重複スキップ(このセッションで処理済み): {final_name}")
            return {"file": final_name, "status": "duplicate_skip"}

        # --- 既存ファイルチェック(Network Volumeによる再DL防止) ---
        if validate_file(final_path, expected_sha256):
            log(f"⏭️ スキップ(既存・検証済み): {final_name}")
            mark_completed(final_path)
            return {"file": final_name, "status": "already_exists"}

        log(f"🚀 開始: [{source.upper()}] ({file_type}) {filename} -> {final_name}")

        success = False
        if source == "civitai":
            tmp_path = os.path.join(save_dir, filename)
            if download_civitai(target, filename, tmp_path):
                if tmp_path != final_path:
                    os.rename(tmp_path, final_path)
                success = True

        elif source == "hf":
            path = download_hf(target, filename, save_dir)
            if path:
                if path != final_path:
                    os.makedirs(os.path.dirname(final_path), exist_ok=True)
                    os.rename(path, final_path)
                success = True

        else:
            log(f"❌ 不明なソース: {source}")
            return {"file": final_name, "status": "unknown_source"}

        if not success:
            return {"file": final_name, "status": "download_failed"}

        # --- ダウンロード後の検証 ---
        if not validate_file(final_path, expected_sha256):
            log(f"❌ 検証失敗のため削除: {final_name}")
            if os.path.exists(final_path):
                os.remove(final_path)
            return {"file": final_name, "status": "validation_failed"}

        mark_completed(final_path)
        log(f"✅ 完了: {final_name}")
        return {"file": final_name, "status": "success"}


# ====================================================================
# メイン
# ====================================================================
def main():
    parser = argparse.ArgumentParser(description="ComfyUI モデル一括ダウンローダー")
    parser.add_argument("--config", default="models.json", help="モデルリストのJSONファイル")
    parser.add_argument("--workers", type=int, default=3, help="並列ダウンロード数")
    args = parser.parse_args()

    if not CIVITAI_TOKEN:
        log("ℹ️ CIVITAI_TOKEN 未設定(非公開モデルはDL不可)")
    if not HF_TOKEN:
        log("ℹ️ HF_TOKEN 未設定(gatedモデルはDL不可)")

    check_network_volume()

    config_path = Path(args.config)
    if not config_path.exists():
        log(f"❌ 設定ファイルが見つかりません: {config_path}")
        sys.exit(1)

    with open(config_path, "r", encoding="utf-8") as f:
        config = json.load(f)

    items = config.get("models", [])
    if not items:
        log("⚠️ models.json にダウンロード対象がありません。")
        return

    log(f"\n📋 {len(items)} 件のモデルを最大 {args.workers} 並列でダウンロードします\n")

    results = []
    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = {executor.submit(process_item, item): item for item in items}
        for future in as_completed(futures):
            item = futures[future]
            try:
                results.append(future.result())
            except Exception as e:
                log(f"💥 例外発生 ({item.get('file')}): {e}")
                results.append({"file": item.get("file"), "status": "exception"})

    # --- サマリー表示 ---
    log("\n" + "=" * 60)
    log("📊 ダウンロード結果サマリー")
    log("=" * 60)
    status_labels = {
        "success": "✅ 成功",
        "already_exists": "⏭️ スキップ(既存)",
        "duplicate_skip": "⏭️ スキップ(重複)",
        "download_failed": "❌ ダウンロード失敗",
        "validation_failed": "❌ 検証失敗",
        "unknown_source": "❌ 不明なソース",
        "exception": "💥 例外",
    }
    for r in results:
        label = status_labels.get(r["status"], r["status"])
        log(f"  {label}: {r['file']}")

    fail_count = sum(1 for r in results if r["status"] in
                      ("download_failed", "validation_failed", "unknown_source", "exception"))
    log("=" * 60)
    if fail_count:
        log(f"⚠️ {fail_count} 件が失敗しました。ログを確認してください。")
        sys.exit(1)
    else:
        log("✨ すべて正常に完了しました。")


if __name__ == "__main__":
    main()
