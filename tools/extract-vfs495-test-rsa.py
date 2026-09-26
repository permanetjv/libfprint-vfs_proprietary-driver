#!/usr/bin/python3
"""Extract the fixed RSA test key embedded in the audited vendor initializer.

The HP/Synaptics 4.5-136.0 initializer contains byte-at-a-time implementations
of palCryptoRsaExportPublicKey and palCryptoRsaExportPrivateKeyBlobData.  This
tool reconstructs their outputs from objdump disassembly.  It does not contain
or redistribute the proprietary key material itself.
"""

import argparse
import hashlib
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


INITIALIZER_SHA256 = "089322826391fad7735407c28c986cf016ce5817637589235273ab7bde20d353"
PRIVATE_BLOB_SIZE = 1184
RSA_BYTES = 256


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def disassemble(objdump: Path, initializer: Path, symbol: str) -> str:
    result = subprocess.run(
        [str(objdump), "-d", "-M", "intel", f"--disassemble={symbol}", str(initializer)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout


def extract_byte_stores(disassembly: str, register: str, expected_size: int) -> bytes:
    pattern = re.compile(
        rf"mov\s+BYTE PTR \[{register}(?:\+0x([0-9a-f]+))?\],0x([0-9a-f]+)"
    )
    values = {}
    for offset_hex, value_hex in pattern.findall(disassembly):
        offset = int(offset_hex or "0", 16)
        value = int(value_hex, 16)
        previous = values.setdefault(offset, value)
        if previous != value:
            raise ValueError(f"conflicting byte stores at offset {offset}")
    expected_offsets = set(range(expected_size))
    if set(values) != expected_offsets:
        missing = sorted(expected_offsets - set(values))
        extra = sorted(set(values) - expected_offsets)
        raise ValueError(f"unexpected byte-store coverage; missing={missing[:8]} extra={extra[:8]}")
    return bytes(values[offset] for offset in range(expected_size))


def validate_private_blob(blob: bytes, public_modulus: bytes) -> tuple[bytes, bytes]:
    if blob[:8] != bytes.fromhex("0702000000240000"):
        raise ValueError("unexpected PRIVATEKEYBLOB header")
    if blob[8:12] != b"RSA2":
        raise ValueError("unexpected RSA private-key magic")
    if int.from_bytes(blob[12:16], "little") != 2048:
        raise ValueError("embedded RSA key is not 2048 bits")
    exponent = int.from_bytes(blob[16:20], "little")
    if exponent != 65537:
        raise ValueError("unexpected RSA public exponent")

    modulus = int.from_bytes(blob[20:276], "little")
    prime_p = int.from_bytes(blob[276:404], "little")
    prime_q = int.from_bytes(blob[404:532], "little")
    exponent_p = int.from_bytes(blob[532:660], "little")
    exponent_q = int.from_bytes(blob[660:788], "little")
    coefficient = int.from_bytes(blob[788:916], "little")
    private_exponent = int.from_bytes(blob[916:1172], "little")

    if blob[1172:] != bytes(PRIVATE_BLOB_SIZE - 1172):
        raise ValueError("unexpected data after PRIVATEKEYBLOB payload")
    if modulus != prime_p * prime_q:
        raise ValueError("embedded RSA modulus does not equal p*q")
    if exponent_p != private_exponent % (prime_p - 1):
        raise ValueError("embedded RSA exponent1 is inconsistent")
    if exponent_q != private_exponent % (prime_q - 1):
        raise ValueError("embedded RSA exponent2 is inconsistent")
    if coefficient != pow(prime_q, -1, prime_p):
        raise ValueError("embedded RSA coefficient is inconsistent")
    if pow(pow(2, exponent, modulus), private_exponent, modulus) != 2:
        raise ValueError("embedded RSA public/private exponents do not match")

    modulus_be = modulus.to_bytes(RSA_BYTES, "big")
    private_exponent_be = private_exponent.to_bytes(RSA_BYTES, "big")
    if modulus_be != public_modulus:
        raise ValueError("public-key export does not match PRIVATEKEYBLOB modulus")
    return modulus_be, private_exponent_be


def write_exclusive(path: Path, payload: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    try:
        view = memoryview(payload)
        while view:
            written = os.write(fd, view)
            view = view[written:]
        os.fsync(fd)
    finally:
        os.close(fd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--initializer", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--objdump", type=Path, default=Path("/usr/bin/objdump"))
    parser.add_argument("--expected-sha256", default=INITIALIZER_SHA256)
    args = parser.parse_args()

    initializer_stat = args.initializer.lstat()
    if not stat.S_ISREG(initializer_stat.st_mode) or args.initializer.is_symlink():
        raise ValueError("initializer must be a regular, non-symlink file")
    if not re.fullmatch(r"[0-9a-f]{64}", args.expected_sha256):
        raise ValueError("expected SHA-256 must be 64 lowercase hexadecimal characters")
    actual_sha256 = sha256(args.initializer)
    if actual_sha256 != args.expected_sha256:
        raise ValueError(f"initializer SHA-256 mismatch: {actual_sha256}")

    output_stat = args.output_dir.lstat()
    if not stat.S_ISDIR(output_stat.st_mode) or args.output_dir.is_symlink():
        raise ValueError("output directory must be a non-symlink directory")

    private_blob = extract_byte_stores(
        disassemble(args.objdump, args.initializer, "palCryptoRsaExportPrivateKeyBlobData"),
        "rsi",
        PRIVATE_BLOB_SIZE,
    )
    public_modulus = extract_byte_stores(
        disassemble(args.objdump, args.initializer, "palCryptoRsaExportPublicKey"),
        "rdi",
        RSA_BYTES,
    )
    sensor_modulus, sensor_private_exponent = validate_private_blob(
        private_blob, public_modulus
    )

    outputs = {
        "ha_pub_mod.bin": public_modulus,
        "ha_priv_blob.bin": private_blob,
        "s_priv_exp.bin": sensor_private_exponent,
        "s_priv_mod.bin": sensor_modulus,
    }
    for name in outputs:
        if (args.output_dir / name).exists() or (args.output_dir / name).is_symlink():
            raise FileExistsError(f"refusing to overwrite {args.output_dir / name}")
    for name, payload in outputs.items():
        write_exclusive(args.output_dir / name, payload)

    directory_fd = os.open(args.output_dir, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    print(
        f"Extracted four root-local RSA test-key files from audited initializer "
        f"{actual_sha256}."
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
