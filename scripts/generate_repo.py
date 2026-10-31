import os
import sys
import hashlib
import bz2
import lzma
import tarfile
import io

try:
    import zstandard as zstd
except ImportError:
    zstd = None

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()

def extract_control_from_deb(deb_path):
    with open(deb_path, "rb") as f:
        magic = f.read(8)
        if magic != b"!<arch>\n":
            raise ValueError(f"Not a valid ar/deb archive: {deb_path}")
        
        while True:
            header = f.read(60)
            if not header or len(header) < 60:
                break
            filename = header[:16].decode("ascii", errors="ignore").strip()
            size = int(header[48:58].decode("ascii", errors="ignore").strip())
            file_data = f.read(size)
            if size % 2 != 0:
                f.read(1)

            if filename.startswith("control.tar"):
                tar_bytes = io.BytesIO(file_data)
                with tarfile.open(fileobj=tar_bytes, mode="r:*") as tar:
                    for member in tar.getmembers():
                        clean_name = member.name.lstrip("./")
                        if clean_name == "control":
                            extracted = tar.extractfile(member)
                            if extracted:
                                return extracted.read().decode("utf-8").strip()
    raise RuntimeError(f"Could not find control file in {deb_path}")

def generate_repo():
    os.makedirs("repo_dist/debs", exist_ok=True)

    # Disable Jekyll
    with open("repo_dist/.nojekyll", "w") as f:
        pass

    # Create Release
    release_content = (
        "Origin: n1ck\n"
        "Label: n1ck's Repo\n"
        "Suite: stable\n"
        "Version: 1.0\n"
        "Codename: ios\n"
        "Architectures: iphoneos-arm64 iphoneos-arm64e\n"
        "Components: main\n"
        "Description: Sileo & APT repository for WiFiUsage\n"
    )
    with open("repo_dist/Release", "w") as f:
        f.write(release_content)

    # Create index.html
    html_content = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>n1ck's Repo</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #0f172a;
      color: #f8fafc;
      display: flex;
      justify-content: center;
      align-items: center;
      min-height: 100vh;
      margin: 0;
      padding: 20px;
      box-sizing: border-box;
    }
    .card {
      background: #1e293b;
      padding: 2rem;
      border-radius: 1rem;
      box-shadow: 0 10px 25px rgba(0,0,0,0.5);
      max-width: 480px;
      width: 100%;
      text-align: center;
    }
    h1 { margin-top: 0; font-size: 1.75rem; color: #38bdf8; }
    p { color: #94a3b8; line-height: 1.6; }
    .btn {
      display: block;
      background: #2563eb;
      color: white;
      text-decoration: none;
      font-weight: 600;
      padding: 12px 20px;
      border-radius: 8px;
      margin-top: 15px;
      transition: background 0.2s;
    }
    .btn:hover { background: #1d4ed8; }
    .btn.sileo { background: #3b82f6; }
    .btn.zebra { background: #10b981; }
    code {
      display: block;
      background: #0f172a;
      padding: 10px;
      border-radius: 6px;
      margin: 15px 0;
      font-size: 0.85rem;
      color: #cbd5e1;
      word-break: break-all;
    }
  </style>
</head>
<body>
  <div class="card">
    <h1>n1ck's Repo</h1>
    <p>Official Sileo & APT repository for <strong>WiFiUsage</strong> (iOS 16 Dopamine rootless).</p>
    <code>https://iamn1ck.github.io/wifiusage-ios/</code>
    <a class="btn sileo" href="sileo://source/https://iamn1ck.github.io/wifiusage-ios/">Add to Sileo</a>
    <a class="btn zebra" href="zbra://sources/add/https://iamn1ck.github.io/wifiusage-ios/">Add to Zebra</a>
  </div>
</body>
</html>
"""
    with open("repo_dist/index.html", "w") as f:
        f.write(html_content)

    # Copy deb files to repo_dist/debs
    import shutil
    import glob
    for deb_file in glob.glob("packages/*.deb"):
        shutil.copy(deb_file, "repo_dist/debs/")

    # Generate Packages index
    debs = [f for f in os.listdir("repo_dist/debs") if f.endswith(".deb")]
    debs.sort()

    packages_entries = []
    for deb in debs:
        rel_path = f"debs/{deb}"
        full_deb_path = os.path.join("repo_dist", rel_path)
        control_text = extract_control_from_deb(full_deb_path)
        size = os.path.getsize(full_deb_path)
        md5 = md5_file(full_deb_path)
        sha256 = sha256_file(full_deb_path)

        entry = (
            f"{control_text}\n"
            f"Filename: {rel_path}\n"
            f"Size: {size}\n"
            f"MD5sum: {md5}\n"
            f"SHA256: {sha256}\n\n"
        )
        packages_entries.append(entry)

    packages_data = "".join(packages_entries).encode("utf-8")

    with open("repo_dist/Packages", "wb") as f:
        f.write(packages_data)
    with open("repo_dist/Packages.bz2", "wb") as f:
        f.write(bz2.compress(packages_data))
    with open("repo_dist/Packages.xz", "wb") as f:
        f.write(lzma.compress(packages_data))

    if zstd:
        with open("repo_dist/Packages.zst", "wb") as f:
            cctx = zstd.ZstdCompressor()
            f.write(cctx.compress(packages_data))

    print(f"Successfully generated Packages index for {len(debs)} package(s).")

if __name__ == "__main__":
    generate_repo()
