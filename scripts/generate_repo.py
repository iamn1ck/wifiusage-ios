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
    # .deb is an ar archive containing debian-binary, control.tar.gz/xz/zst, data.tar...
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
                f.read(1) # ar 2-byte alignment padding

            if filename.startswith("control.tar"):
                # Untar control file
                tar_bytes = io.BytesIO(file_data)
                mode = "r:*"
                with tarfile.open(fileobj=tar_bytes, mode=mode) as tar:
                    for member in tar.getmembers():
                        clean_name = member.name.lstrip("./")
                        if clean_name == "control":
                            extracted = tar.extractfile(member)
                            if extracted:
                                return extracted.read().decode("utf-8").strip()
    raise RuntimeError(f"Could not find control file in {deb_path}")

def generate_repo():
    debs_dir = "debs"
    if not os.path.exists(debs_dir):
        print(f"Directory '{debs_dir}' does not exist.")
        return

    debs = [f for f in os.listdir(debs_dir) if f.endswith(".deb")]
    debs.sort()

    if not debs:
        print("No .deb files found in debs/.")
        return

    packages_entries = []
    for deb in debs:
        rel_path = f"{debs_dir}/{deb}"
        control_text = extract_control_from_deb(rel_path)
        size = os.path.getsize(rel_path)
        md5 = md5_file(rel_path)
        sha256 = sha256_file(rel_path)

        entry = (
            f"{control_text}\n"
            f"Filename: {rel_path}\n"
            f"Size: {size}\n"
            f"MD5sum: {md5}\n"
            f"SHA256: {sha256}\n\n"
        )
        packages_entries.append(entry)

    packages_data = "".join(packages_entries).encode("utf-8")

    with open("Packages", "wb") as f:
        f.write(packages_data)
    with open("Packages.bz2", "wb") as f:
        f.write(bz2.compress(packages_data))
    with open("Packages.xz", "wb") as f:
        f.write(lzma.compress(packages_data))

    if zstd:
        with open("Packages.zst", "wb") as f:
            cctx = zstd.ZstdCompressor()
            f.write(cctx.compress(packages_data))

    print(f"Successfully generated Packages index for {len(debs)} package(s).")

if __name__ == "__main__":
    generate_repo()

