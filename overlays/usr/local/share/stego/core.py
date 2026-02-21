#!/usr/bin/env python3
"""
Steganography Core Module
Shared logic for hiding and scanning encrypted data in files.
"""

import os
import mmap
import tarfile
import hashlib
import struct
import tempfile
import shutil
from pathlib import Path
from typing import Callable, Optional, Dict, Any

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.backends import default_backend

# Magic marker to identify hidden data — note: STEG-zero-DATA, not letter O
MAGIC_MARKER = b'STEG0DATA'
VERSION = 1


class StegoError(Exception):
    """Custom exception for steganography errors"""
    pass


class StegoCore:
    """Core steganography functionality"""

    def __init__(self):
        self.backend = default_backend()

    def derive_key(self, password: str, salt: bytes) -> bytes:
        """Derive encryption key from password using PBKDF2"""
        kdf = PBKDF2HMAC(
            algorithm=hashes.SHA256(),
            length=32,
            salt=salt,
            iterations=100000,
            backend=self.backend
        )
        return kdf.derive(password.encode())

    def encrypt_data(self, data: bytes, password: str) -> bytes:
        """Encrypt data using AES-256-CBC"""
        salt = os.urandom(16)
        key = self.derive_key(password, salt)
        iv = os.urandom(16)

        cipher = Cipher(
            algorithms.AES(key),
            modes.CBC(iv),
            backend=self.backend
        )
        encryptor = cipher.encryptor()

        # Pad data to AES block size (16 bytes)
        padding_length = 16 - (len(data) % 16)
        padded_data = data + bytes([padding_length] * padding_length)

        encrypted = encryptor.update(padded_data) + encryptor.finalize()

        # Return salt + iv + encrypted data
        return salt + iv + encrypted

    def decrypt_data(self, encrypted_data: bytes, password: str) -> bytes:
        """Decrypt data using AES-256-CBC"""
        if len(encrypted_data) < 32:
            raise StegoError("Invalid encrypted data")

        salt = encrypted_data[:16]
        iv = encrypted_data[16:32]
        ciphertext = encrypted_data[32:]

        key = self.derive_key(password, salt)

        cipher = Cipher(
            algorithms.AES(key),
            modes.CBC(iv),
            backend=self.backend
        )
        decryptor = cipher.decryptor()

        padded_data = decryptor.update(ciphertext) + decryptor.finalize()

        # Remove padding
        padding_length = padded_data[-1]
        return padded_data[:-padding_length]

    def create_tarball(self, source: Path, output_file: Path) -> None:
        """Create a tar.gz archive from a file or directory"""
        with tarfile.open(output_file, 'w:gz') as tar:
            if source.is_file():
                tar.add(source, arcname=f'data/{source.name}')
            else:
                tar.add(source, arcname='data')

    def extract_tarball(self, tarball_path: Path, extract_to: Path) -> None:
        """Extract tar.gz archive, guarding against path traversal"""
        with tarfile.open(tarball_path, 'r:gz') as tar:
            try:
                # filter='data' strips dangerous members (Python >= 3.11.4)
                tar.extractall(extract_to, filter='data')
            except TypeError:
                # Python < 3.11.4: validate every member path manually
                extract_to_str = str(extract_to.resolve()) + os.sep
                for member in tar.getmembers():
                    dest = os.path.normpath(
                        os.path.join(str(extract_to.resolve()), member.name)
                    )
                    if not (dest + os.sep).startswith(extract_to_str) and \
                            dest != str(extract_to.resolve()):
                        raise StegoError(f"Unsafe path in archive: {member.name}")
                tar.extractall(extract_to)

    def hide_data(self,
                  data_path: Path,
                  carrier_file: Path,
                  output_file: Path,
                  password: str,
                  progress_callback: Optional[Callable[[int, str], None]] = None) -> Dict[str, Any]:
        """
        Hide encrypted data in a carrier file.

        Args:
            data_path: File or folder to hide
            carrier_file: File to use as carrier
            output_file: Where to save the result
            password: Encryption password
            progress_callback: Optional callback(step, message) for progress updates

        Returns:
            Dictionary with statistics
        """
        if not data_path.exists():
            raise StegoError(f"Data path not found: {data_path}")
        if not carrier_file.exists():
            raise StegoError(f"Carrier file not found: {carrier_file}")

        temp_tar_fd, temp_tar_path = tempfile.mkstemp(suffix='.tar.gz', prefix='stego_temp_')
        os.close(temp_tar_fd)
        temp_tar = Path(temp_tar_path)

        try:
            if progress_callback:
                progress_callback(1, "Creating archive...")

            self.create_tarball(data_path, temp_tar)

            with open(temp_tar, 'rb') as f:
                tar_data = f.read()

            if progress_callback:
                progress_callback(2, "Encrypting data...")

            encrypted_data = self.encrypt_data(tar_data, password)
            checksum = hashlib.sha256(encrypted_data).digest()

            with open(carrier_file, 'rb') as f:
                carrier_data = f.read()

            original_filename = carrier_file.name.encode('utf-8')

            hidden_structure = (
                MAGIC_MARKER +
                struct.pack('B', VERSION) +
                checksum +
                struct.pack('H', len(original_filename)) +
                original_filename +
                struct.pack('Q', len(encrypted_data)) +
                encrypted_data
            )

            if progress_callback:
                progress_callback(3, "Writing output file...")

            with open(output_file, 'wb') as f:
                f.write(carrier_data)
                f.write(hidden_structure)

            return {
                'carrier_size': len(carrier_data),
                'hidden_size': len(hidden_structure),
                'output_size': len(carrier_data) + len(hidden_structure),
                'files_count': 1 if data_path.is_file() else sum(1 for _ in data_path.rglob('*') if _.is_file())
            }

        finally:
            temp_tar.unlink(missing_ok=True)

    def show_data(self,
                  input_file: Path,
                  output_folder: Path,
                  password: str,
                  progress_callback: Optional[Callable[[int, str], None]] = None) -> Dict[str, Any]:
        """
        Extract hidden data from a file.

        Args:
            input_file: File containing hidden data
            output_folder: Folder to extract data to
            password: Decryption password
            progress_callback: Optional callback(step, message) for progress updates

        Returns:
            Dictionary with statistics
        """
        if progress_callback:
            progress_callback(1, "Reading file...")

        with open(input_file, 'rb') as f:
            with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
                marker_pos = mm.rfind(MAGIC_MARKER)
                if marker_pos == -1:
                    raise StegoError("No hidden data found in file")

                offset = marker_pos + len(MAGIC_MARKER)

                version = struct.unpack('B', mm[offset:offset+1])[0]
                offset += 1
                if version != VERSION:
                    raise StegoError(f"Unsupported version: {version}")

                checksum = bytes(mm[offset:offset+32])
                offset += 32

                filename_length = struct.unpack('H', mm[offset:offset+2])[0]
                offset += 2

                original_filename = mm[offset:offset+filename_length].decode('utf-8')
                offset += filename_length

                data_length = struct.unpack('Q', mm[offset:offset+8])[0]
                offset += 8

                encrypted_data = bytes(mm[offset:offset+data_length])

                # Verify checksum
                calculated_checksum = hashlib.sha256(encrypted_data).digest()
                if calculated_checksum != checksum:
                    raise StegoError("Checksum mismatch - data may be corrupted")

                if progress_callback:
                    progress_callback(2, "Decrypting data...")

                try:
                    decrypted_data = self.decrypt_data(encrypted_data, password)
                except Exception as e:
                    raise StegoError(f"Decryption failed - wrong password? ({e})")

                # Create output structure
                output_folder.mkdir(parents=True, exist_ok=True)
                data_folder = output_folder / 'data'
                original_folder = output_folder / 'original'
                data_folder.mkdir(exist_ok=True)
                original_folder.mkdir(exist_ok=True)

                # Stream carrier data directly from mmap — avoids loading it into RAM
                original_file_path = original_folder / original_filename
                chunk_size = 4 * 1024 * 1024  # 4 MB
                with open(original_file_path, 'wb') as out_f:
                    mm.seek(0)
                    remaining = marker_pos
                    while remaining > 0:
                        chunk = mm.read(min(chunk_size, remaining))
                        out_f.write(chunk)
                        remaining -= len(chunk)

                original_size = marker_pos

        if progress_callback:
            progress_callback(3, "Extracting archive...")

        temp_tar_fd, temp_tar_path = tempfile.mkstemp(suffix='.tar.gz', prefix='stego_extract_')
        os.close(temp_tar_fd)
        temp_tar = Path(temp_tar_path)

        try:
            with open(temp_tar, 'wb') as f:
                f.write(decrypted_data)
            self.extract_tarball(temp_tar, output_folder)
        finally:
            temp_tar.unlink(missing_ok=True)

        files_count = sum(1 for _ in data_folder.rglob('*') if _.is_file())

        return {
            'original_filename': original_filename,
            'original_size': original_size,
            'hidden_size': data_length,
            'files_count': files_count
        }

    def scan_file(self, file_path: Path) -> Dict[str, Any]:
        """
        Scan a file for hidden data.

        Args:
            file_path: File to scan

        Returns:
            Dictionary with scan results
        """
        result = {
            'file': str(file_path),
            'has_hidden_data': False,
            'marker_position': None,
            'version': None,
            'original_filename': None,
            'hidden_size': None,
            'file_size': None
        }

        try:
            with open(file_path, 'rb') as f:
                file_data = f.read()

            result['file_size'] = len(file_data)

            marker_pos = file_data.rfind(MAGIC_MARKER)

            if marker_pos != -1:
                result['has_hidden_data'] = True
                result['marker_position'] = marker_pos

                offset = marker_pos + len(MAGIC_MARKER)

                version = struct.unpack('B', file_data[offset:offset+1])[0]
                result['version'] = version
                offset += 1 + 32  # skip version and checksum

                filename_length = struct.unpack('H', file_data[offset:offset+2])[0]
                offset += 2

                original_filename = file_data[offset:offset+filename_length].decode('utf-8', errors='ignore')
                result['original_filename'] = original_filename
                offset += filename_length

                data_length = struct.unpack('Q', file_data[offset:offset+8])[0]
                result['hidden_size'] = data_length

        except Exception as e:
            result['error'] = str(e)

        return result

    def scan_files(self,
                   path: Path,
                   recursive: bool = False,
                   include_hidden: bool = False,
                   progress_callback: Optional[Callable[[int, int], None]] = None) -> list:
        """
        Scan files for hidden data.

        Args:
            path: File or directory to scan
            recursive: Scan subdirectories
            include_hidden: Include hidden files
            progress_callback: Optional callback(current, total) for progress

        Returns:
            List of scan results
        """
        if path.is_file():
            files = [path]
        else:
            files = list(path.rglob('*') if recursive else path.glob('*'))
            files = [f for f in files if f.is_file()]

            if not include_hidden:
                files = [f for f in files if not any(part.startswith('.') for part in f.parts)]

        total = len(files)
        results = []

        for i, file_path in enumerate(files):
            if progress_callback:
                progress_callback(i + 1, total)
            results.append(self.scan_file(file_path))

        return results
