#!/usr/bin/env python3
"""
Steganography Core Module
Shared logic for hiding, showing, and scanning encrypted data in files.
Used by both CLI and GUI interfaces.
"""

import os
import tarfile
import hashlib
import struct
import tempfile
import shutil
from pathlib import Path
from typing import Callable, Optional, Dict, Any, List

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.backends import default_backend

# Magic marker to identify hidden data
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
        if padding_length > 16 or padding_length == 0:
            raise StegoError("Invalid password or corrupted data")
        return padded_data[:-padding_length]

    def create_tarball(self, source_dir: Path, output_file: Path) -> None:
        """Create a tar.gz archive from a directory"""
        with tarfile.open(output_file, 'w:gz') as tar:
            tar.add(source_dir, arcname='data')

    def extract_tarball(self, tarball_path: Path, extract_to: Path) -> None:
        """Extract tar.gz archive"""
        with tarfile.open(tarball_path, 'r:gz') as tar:
            tar.extractall(extract_to)

    def hide_data(self,
                  data_folder: Path,
                  carrier_file: Path,
                  output_file: Path,
                  password: str,
                  progress_callback: Optional[Callable[[int, str], None]] = None) -> Dict[str, Any]:
        """
        Hide encrypted data in a carrier file.

        Args:
            data_folder: Folder containing files to hide
            carrier_file: File to use as carrier
            output_file: Where to save the result
            password: Encryption password
            progress_callback: Optional callback(step, message) for progress

        Returns:
            Dictionary with statistics
        """
        if not data_folder.exists():
            raise StegoError(f"Data folder not found: {data_folder}")
        if not carrier_file.exists():
            raise StegoError(f"Carrier file not found: {carrier_file}")

        stats = {}
        tmp_dir = tempfile.mkdtemp()

        try:
            # Step 1: Create archive
            if progress_callback:
                progress_callback(1, "Creating archive...")

            tarball_path = Path(tmp_dir) / 'data.tar.gz'
            self.create_tarball(data_folder, tarball_path)

            with open(tarball_path, 'rb') as f:
                archive_data = f.read()

            stats['archive_size'] = len(archive_data)

            # Step 2: Encrypt
            if progress_callback:
                progress_callback(2, "Encrypting data...")

            encrypted = self.encrypt_data(archive_data, password)
            stats['encrypted_size'] = len(encrypted)

            # Step 3: Calculate checksum
            checksum = hashlib.sha256(encrypted).digest()

            # Step 4: Read carrier file
            if progress_callback:
                progress_callback(3, "Reading carrier file...")

            with open(carrier_file, 'rb') as f:
                carrier_data = f.read()

            stats['carrier_size'] = len(carrier_data)
            original_filename = carrier_file.name

            # Step 5: Build hidden data block
            # Format: MAGIC | VERSION(1B) | filename_len(2B) | filename | checksum(32B) | data_len(4B) | encrypted_data
            filename_bytes = original_filename.encode('utf-8')
            hidden_block = (
                MAGIC_MARKER +
                struct.pack('B', VERSION) +
                struct.pack('>H', len(filename_bytes)) +
                filename_bytes +
                checksum +
                struct.pack('>I', len(encrypted)) +
                encrypted
            )

            # Step 6: Write output
            if progress_callback:
                progress_callback(4, "Writing output file...")

            output_file.parent.mkdir(parents=True, exist_ok=True)
            with open(output_file, 'wb') as f:
                f.write(carrier_data)
                f.write(hidden_block)

            stats['output_size'] = len(carrier_data) + len(hidden_block)
            stats['output_file'] = str(output_file)

            if progress_callback:
                progress_callback(5, "Done!")

            return stats

        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)

    def show_data(self,
                  input_file: Path,
                  output_folder: Path,
                  password: str,
                  progress_callback: Optional[Callable[[int, str], None]] = None) -> Dict[str, Any]:
        """
        Extract hidden data from a carrier file.

        Args:
            input_file: File containing hidden data
            output_folder: Where to extract
            password: Decryption password
            progress_callback: Optional callback(step, message)

        Returns:
            Dictionary with statistics
        """
        if not input_file.exists():
            raise StegoError(f"Input file not found: {input_file}")

        stats = {}

        # Step 1: Read file
        if progress_callback:
            progress_callback(1, "Reading file...")

        with open(input_file, 'rb') as f:
            file_data = f.read()

        # Step 2: Find marker
        marker_pos = file_data.rfind(MAGIC_MARKER)
        if marker_pos == -1:
            raise StegoError("No hidden data found in this file")

        # Step 3: Parse header
        pos = marker_pos + len(MAGIC_MARKER)

        version = struct.unpack('B', file_data[pos:pos + 1])[0]
        pos += 1

        if version != VERSION:
            raise StegoError(f"Unsupported version: {version}")

        filename_len = struct.unpack('>H', file_data[pos:pos + 2])[0]
        pos += 2

        original_filename = file_data[pos:pos + filename_len].decode('utf-8')
        pos += filename_len

        stored_checksum = file_data[pos:pos + 32]
        pos += 32

        data_len = struct.unpack('>I', file_data[pos:pos + 4])[0]
        pos += 4

        encrypted_data = file_data[pos:pos + data_len]

        # Step 4: Verify checksum
        if progress_callback:
            progress_callback(2, "Verifying integrity...")

        actual_checksum = hashlib.sha256(encrypted_data).digest()
        if actual_checksum != stored_checksum:
            raise StegoError("Data integrity check failed — file may be corrupted")

        stats['hidden_size'] = data_len

        # Step 5: Decrypt
        if progress_callback:
            progress_callback(3, "Decrypting data...")

        try:
            decrypted = self.decrypt_data(encrypted_data, password)
        except Exception:
            raise StegoError("Decryption failed — wrong password or corrupted data")

        # Step 6: Extract
        if progress_callback:
            progress_callback(4, "Extracting archive...")

        tmp_dir = tempfile.mkdtemp()
        try:
            tarball_path = Path(tmp_dir) / 'data.tar.gz'
            with open(tarball_path, 'wb') as f:
                f.write(decrypted)

            # Create output structure
            output_folder.mkdir(parents=True, exist_ok=True)
            data_out = output_folder
            original_out = output_folder / 'original'
            original_out.mkdir(parents=True, exist_ok=True)

            # Extract archive
            self.extract_tarball(tarball_path, data_out)

            # Write clean original carrier
            original_data = file_data[:marker_pos]
            original_file_path = original_out / original_filename
            with open(original_file_path, 'wb') as f:
                f.write(original_data)

            stats['original_file'] = original_filename
            stats['original_size'] = len(original_data)
            stats['output_folder'] = str(output_folder)

            if progress_callback:
                progress_callback(5, "Done!")

            return stats

        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)

    def scan_file(self, file_path: Path) -> Optional[Dict[str, Any]]:
        """
        Scan a single file for hidden data.

        Returns:
            Dictionary with info if hidden data found, None otherwise
        """
        try:
            with open(file_path, 'rb') as f:
                file_data = f.read()

            marker_pos = file_data.rfind(MAGIC_MARKER)
            if marker_pos == -1:
                return None

            # Parse header
            pos = marker_pos + len(MAGIC_MARKER)
            version = struct.unpack('B', file_data[pos:pos + 1])[0]
            pos += 1

            filename_len = struct.unpack('>H', file_data[pos:pos + 2])[0]
            pos += 2

            original_filename = file_data[pos:pos + filename_len].decode('utf-8')
            pos += filename_len

            pos += 32  # skip checksum

            data_len = struct.unpack('>I', file_data[pos:pos + 4])[0]

            return {
                'file': str(file_path),
                'marker_position': marker_pos,
                'version': version,
                'original_filename': original_filename,
                'hidden_size': data_len,
                'file_size': len(file_data),
                'has_hidden_data': True
            }
        except Exception:
            return None

    def scan_path(self,
                  path: Path,
                  recursive: bool = False,
                  include_hidden: bool = False,
                  progress_callback: Optional[Callable[[int, str], None]] = None) -> List[Dict[str, Any]]:
        """
        Scan a file or directory for hidden data.

        Args:
            path: File or directory to scan
            recursive: Scan subdirectories
            include_hidden: Include hidden files (starting with .)
            progress_callback: Optional callback(current, message)

        Returns:
            List of results for files containing hidden data
        """
        results = []

        if path.is_file():
            files = [path]
        elif path.is_dir():
            if recursive:
                files = [f for f in path.rglob('*') if f.is_file()]
            else:
                files = [f for f in path.iterdir() if f.is_file()]

            if not include_hidden:
                files = [f for f in files if not f.name.startswith('.')]
        else:
            raise StegoError(f"Path not found: {path}")

        total = len(files)
        for i, file_path in enumerate(files):
            if progress_callback:
                progress_callback(i + 1, f"Scanning ({i + 1}/{total}): {file_path.name}")

            result = self.scan_file(file_path)
            if result:
                results.append(result)

        return results
