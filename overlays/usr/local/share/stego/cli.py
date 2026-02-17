#!/usr/bin/env python3
"""
Steganography CLI
Command-line interface for hiding, showing, and scanning encrypted data in files.
"""

import sys
import os
import argparse
import getpass
import itertools
import threading
import time
from pathlib import Path

# Import from same directory
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from core import StegoCore, StegoError


class Colors:
    """ANSI color codes"""
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;36m'
    BOLD = '\033[1m'
    NC = '\033[0m'

    @classmethod
    def disable(cls):
        cls.RED = cls.GREEN = cls.YELLOW = cls.BLUE = cls.BOLD = cls.NC = ''


class Spinner:
    """Animated spinner for progress feedback"""
    def __init__(self):
        self._spinner = itertools.cycle(['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'])
        self._running = False
        self._thread = None
        self._message = ""

    def start(self, message=""):
        self._message = message
        self._running = True
        self._thread = threading.Thread(target=self._spin, daemon=True)
        self._thread.start()

    def _spin(self):
        while self._running:
            sys.stdout.write(f'\r{next(self._spinner)} {self._message}')
            sys.stdout.flush()
            time.sleep(0.1)

    def update(self, message):
        self._message = message

    def stop(self, final_message=None):
        self._running = False
        if self._thread:
            self._thread.join()
        if final_message:
            sys.stdout.write(f'\r{Colors.GREEN}✓{Colors.NC} {final_message}\n')
        else:
            sys.stdout.write('\r')
        sys.stdout.flush()


def format_size(size_bytes):
    """Format byte size to human readable string"""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} TB"


def hide_command(args):
    """Execute hide command"""
    core = StegoCore()
    base_folder = args.folder.resolve()
    data_dir = base_folder / 'data'
    original_dir = base_folder / 'original'

    if not data_dir.exists():
        print(f"{Colors.RED}Error: data/ folder not found in {base_folder}{Colors.NC}")
        return 1
    if not original_dir.exists():
        print(f"{Colors.RED}Error: original/ folder not found in {base_folder}{Colors.NC}")
        return 1

    carrier_files = [f for f in original_dir.iterdir() if f.is_file()]
    if not carrier_files:
        print(f"{Colors.RED}Error: No carrier file found in {original_dir}{Colors.NC}")
        return 1
    if len(carrier_files) > 1:
        print(f"{Colors.RED}Error: Multiple files in {original_dir}. Keep only one carrier file.{Colors.NC}")
        return 1

    carrier_file = carrier_files[0]
    password = args.password or getpass.getpass('Enter encryption password: ')
    if not password:
        print("Error: Password cannot be empty")
        return 1

    # Confirm password
    if not args.password:
        confirm = getpass.getpass('Confirm password: ')
        if password != confirm:
            print(f"{Colors.RED}Error: Passwords don't match{Colors.NC}")
            return 1

    spinner = Spinner()

    def progress(step, message):
        if args.verbose:
            print(f"[*] {message}")
        else:
            spinner.update(message)

    if not args.verbose:
        spinner.start("Starting...")

    try:
        stats = core.hide_data(
            data_folder=data_dir,
            carrier_file=carrier_file,
            output_file=args.output.resolve(),
            password=password,
            progress_callback=progress
        )

        if not args.verbose:
            spinner.stop("Done!")

        print(f"\n{Colors.GREEN}{Colors.BOLD}Data hidden successfully!{Colors.NC}")
        print(f"  Carrier:   {carrier_file.name} ({format_size(stats['carrier_size'])})")
        print(f"  Hidden:    {format_size(stats['archive_size'])} → {format_size(stats['encrypted_size'])} encrypted")
        print(f"  Output:    {args.output} ({format_size(stats['output_size'])})")
        print()

        return 0

    except StegoError as e:
        if not args.verbose:
            spinner.stop()
        print(f"{Colors.RED}Error: {e}{Colors.NC}")
        return 1


def show_command(args):
    """Execute show command"""
    core = StegoCore()
    password = args.password or getpass.getpass('Enter decryption password: ')
    if not password:
        print("Error: Password cannot be empty")
        return 1

    spinner = Spinner()

    def progress(step, message):
        if args.verbose:
            print(f"[*] {message}")
        else:
            spinner.update(message)

    if not args.verbose:
        spinner.start("Starting...")

    try:
        stats = core.show_data(
            input_file=args.file.resolve(),
            output_folder=args.output.resolve(),
            password=password,
            progress_callback=progress
        )

        if not args.verbose:
            spinner.stop("Done!")

        print(f"\n{Colors.GREEN}{Colors.BOLD}Data extracted successfully!{Colors.NC}")
        print(f"  Original:  {stats['original_file']} ({format_size(stats['original_size'])})")
        print(f"  Extracted:  {stats['output_folder']}")
        print(f"    data/       Your hidden files")
        print(f"    original/   Clean carrier file")
        print()

        return 0

    except StegoError as e:
        if not args.verbose:
            spinner.stop()
        print(f"{Colors.RED}Error: {e}{Colors.NC}")
        return 1


def scan_command(args):
    """Execute scan command"""
    core = StegoCore()
    path = args.path.resolve()

    def progress(current, message):
        if args.verbose:
            print(f"[*] {message}")

    try:
        results = core.scan_path(
            path=path,
            recursive=args.recursive,
            include_hidden=getattr(args, 'all', False),
            progress_callback=progress
        )

        found_count = len(results)

        if not results:
            print(f"\n{Colors.BLUE}[*] No hidden data found{Colors.NC}\n")
            return 0

        print()
        for result in results:
            print(f"{Colors.GREEN}[+] Hidden data found in: {result['file']}{Colors.NC}")
            if args.verbose:
                print(f"    Position:     {result['marker_position']}")
                print(f"    Version:      {result['version']}")
                print(f"    Original:     {result['original_filename']}")
                print(f"    Hidden size:  {format_size(result['hidden_size'])}")
                print(f"    File size:    {format_size(result['file_size'])}")

        print(f"\n{Colors.BLUE}[*] Scan complete: {found_count} file(s) contain hidden data{Colors.NC}\n")

        return 0

    except StegoError as e:
        print(f"{Colors.RED}Error: {e}{Colors.NC}")
        return 1


def main():
    """Main CLI entry point"""
    parser = argparse.ArgumentParser(
        description='Steganography tool — hide encrypted data in any file type',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  Hide data:
    stego hide /path/to/folder -o output.jpg

  Show data:
    stego show hidden_file.jpg -o /path/to/output

  Scan files:
    stego scan /path/to/files -r -v
    stego scan image.png

For GUI interface, run: stego-gui
        """
    )

    # Disable colors if not a TTY
    if not sys.stdout.isatty():
        Colors.disable()

    subparsers = parser.add_subparsers(dest='command', help='Command to execute')

    # Hide command
    hide_parser = subparsers.add_parser('hide',
        help='Hide encrypted data in a file',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="""Hide encrypted data in a carrier file.

Required folder structure:
  your_folder/
  ├── data/        Files you want to hide (can contain subdirectories)
  └── original/    ONE carrier file (image, video, document, etc.)

Example:
  mkdir -p project/data project/original
  cp secret.txt project/data/
  cp photo.jpg project/original/
  stego hide project -o hidden.jpg
""")
    hide_parser.add_argument('folder', type=Path,
        help='Folder containing data/ and original/ subdirectories')
    hide_parser.add_argument('-o', '--output', type=Path, required=True,
        help='Output file path')
    hide_parser.add_argument('-p', '--password', type=str,
        help='Encryption password (will prompt if not provided)')
    hide_parser.add_argument('-v', '--verbose', action='store_true',
        help='Verbose output')

    # Show command
    show_parser = subparsers.add_parser('show',
        help='Extract hidden data from a file',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="""Extract hidden data from a carrier file.

Creates folder structure:
  output_folder/
  ├── data/        Your extracted hidden files
  └── original/    Original carrier file (clean, without hidden data)

Example:
  stego show hidden.jpg -o extracted_folder
""")
    show_parser.add_argument('file', type=Path,
        help='File containing hidden data')
    show_parser.add_argument('-o', '--output', type=Path, required=True,
        help='Output folder path')
    show_parser.add_argument('-p', '--password', type=str,
        help='Decryption password (will prompt if not provided)')
    show_parser.add_argument('-v', '--verbose', action='store_true',
        help='Verbose output')

    # Scan command
    scan_parser = subparsers.add_parser('scan',
        help='Scan files for hidden data')
    scan_parser.add_argument('path', type=Path,
        help='File or directory to scan')
    scan_parser.add_argument('-r', '--recursive', action='store_true',
        help='Scan subdirectories recursively')
    scan_parser.add_argument('-a', '--all', action='store_true',
        help='Include hidden files (starting with .)')
    scan_parser.add_argument('-v', '--verbose', action='store_true',
        help='Verbose output')

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return 1

    try:
        if args.command == 'hide':
            return hide_command(args)
        elif args.command == 'show':
            return show_command(args)
        elif args.command == 'scan':
            return scan_command(args)
    except KeyboardInterrupt:
        print("\nAborted by user")
        return 130
    except Exception as e:
        print(f"{Colors.RED}Unexpected error: {e}{Colors.NC}", file=sys.stderr)
        if hasattr(args, 'verbose') and args.verbose:
            import traceback
            traceback.print_exc()
        return 1

    return 0


if __name__ == '__main__':
    sys.exit(main())
