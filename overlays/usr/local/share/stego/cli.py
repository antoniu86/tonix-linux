#!/usr/bin/env python3
"""
Steganography CLI
Command-line interface for hiding, showing, and scanning encrypted data
"""

import sys
import argparse
import getpass
from pathlib import Path

from core import StegoCore, StegoError


# ANSI color codes for terminal output
class Colors:
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    BOLD = '\033[1m'
    RESET = '\033[0m'

    @classmethod
    def disable(cls):
        """Disable colors for non-TTY output"""
        cls.RED = cls.GREEN = cls.YELLOW = cls.BLUE = cls.BOLD = cls.RESET = ''


def format_size(size_bytes: int) -> str:
    """Format bytes to human-readable size"""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size_bytes < 1024.0:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024.0
    return f"{size_bytes:.1f} TB"


def print_warning_box():
    """Print critical warning about file modification"""
    c = Colors

    print(f"\n{c.RED}{c.BOLD}{'━' * 60}{c.RESET}")
    print(f"{c.RED}{c.BOLD}⚠️  CRITICAL WARNING{c.RESET}")
    print(f"{c.RED}{c.BOLD}{'━' * 60}{c.RESET}\n")

    print(f"  {c.BOLD}DO NOT modify the output file or hidden data will be lost!{c.RESET}\n")

    print(f"  {c.RED}UNSAFE operations (will destroy hidden data):{c.RESET}")
    print(f"    ✗ Opening in image editors (Photoshop, GIMP, etc.)")
    print(f"    ✗ Compressing or optimizing the file")
    print(f"    ✗ Converting to another format")
    print(f"    ✗ Uploading to social media (auto-optimizes)")
    print(f"    ✗ Emailing (may compress attachments)")
    print(f"    ✗ Re-saving in any program\n")

    print(f"  {c.GREEN}SAFE operations (preserves hidden data):{c.RESET}")
    print(f"    ✓ Copy/move the file as-is (cp, mv, Ctrl+C)")
    print(f"    ✓ View without saving changes")
    print(f"    ✓ Transfer via USB/direct file copy")
    print(f"    ✓ Verify with: stego scan <file>\n")

    print(f"{c.RED}{c.BOLD}{'━' * 60}{c.RESET}\n")


def hide_command(args):
    """Handle hide command"""
    core = StegoCore()

    carrier_file = args.carrier
    data_path = args.data

    if not carrier_file.is_file():
        print(f"Error: Carrier file not found: {carrier_file}", file=sys.stderr)
        return 1

    if not data_path.exists():
        print(f"Error: Data path not found: {data_path}", file=sys.stderr)
        return 1

    if args.verbose:
        print(f"[*] Carrier file: {carrier_file}")
        print(f"[*] Data: {data_path}")

    # Get password
    if args.password:
        password = args.password
        print("Warning: Password specified on command line (insecure!)", file=sys.stderr)
    else:
        password = getpass.getpass('Enter encryption password: ')
        if not password:
            print("Error: Password cannot be empty", file=sys.stderr)
            return 1
        confirm = getpass.getpass('Confirm encryption password: ')
        if password != confirm:
            print("Error: Passwords do not match", file=sys.stderr)
            return 1

    def progress(step, message):
        if args.verbose:
            print(f"[*] {message}")

    try:
        if args.verbose:
            print(f"[*] Hiding data...")

        stats = core.hide_data(
            data_path=data_path,
            carrier_file=carrier_file,
            output_file=args.output,
            password=password,
            progress_callback=progress if args.verbose else None
        )

        print(f"\n{Colors.GREEN}[+] Data successfully hidden in: {args.output}{Colors.RESET}")

        print_warning_box()

        print(f"Details:")
        print(f"  Original carrier size: {format_size(stats['carrier_size'])}")
        print(f"  Hidden data size: {format_size(stats['hidden_size'])}")
        print(f"  Final file size: {format_size(stats['output_size'])}")
        print(f"  Files hidden: {stats['files_count']}\n")

        print(f"{Colors.YELLOW}Keep your password safe - you'll need it to extract the data!{Colors.RESET}\n")

        return 0

    except StegoError as e:
        print(f"{Colors.RED}Error: {e}{Colors.RESET}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"{Colors.RED}Unexpected error: {e}{Colors.RESET}", file=sys.stderr)
        if args.verbose:
            import traceback
            traceback.print_exc()
        return 1


def show_command(args):
    """Handle show command"""
    core = StegoCore()

    if not args.file.exists():
        print(f"Error: File not found: {args.file}", file=sys.stderr)
        return 1

    if args.verbose:
        print(f"[*] Input file: {args.file}")
        print(f"[*] Output folder: {args.output}")

    # Get password
    if args.password:
        password = args.password
        print("Warning: Password specified on command line (insecure!)", file=sys.stderr)
    else:
        password = getpass.getpass('Enter decryption password: ')
        if not password:
            print("Error: Password cannot be empty", file=sys.stderr)
            return 1

    def progress(step, message):
        if args.verbose:
            print(f"[*] {message}")

    try:
        stats = core.show_data(
            input_file=args.file,
            output_folder=args.output,
            password=password,
            progress_callback=progress if args.verbose else None
        )

        print(f"\n{Colors.GREEN}[+] Data successfully extracted to: {args.output}{Colors.RESET}\n")

        print(f"Details:")
        print(f"  Original filename: {stats['original_filename']}")
        print(f"  Original file size: {format_size(stats['original_size'])}")
        print(f"  Hidden data size: {format_size(stats['hidden_size'])}")
        print(f"  Files extracted: {stats['files_count']}\n")

        print(f"Extracted structure:")
        print(f"  {args.output}/")
        print(f"  ├── data/       (your hidden files)")
        print(f"  └── original/   (clean carrier file)\n")

        return 0

    except StegoError as e:
        print(f"{Colors.RED}Error: {e}{Colors.RESET}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"{Colors.RED}Unexpected error: {e}{Colors.RESET}", file=sys.stderr)
        if args.verbose:
            import traceback
            traceback.print_exc()
        return 1


def scan_command(args):
    """Handle scan command"""
    core = StegoCore()

    if not args.path.exists():
        print(f"Error: Path not found: {args.path}", file=sys.stderr)
        return 1

    print(f"[*] Scanning {'recursively ' if args.recursive else ''}{args.path}...\n")

    def progress(current, total):
        if not args.verbose:
            percent = int((current / total) * 100)
            bar_length = 30
            filled = int((current / total) * bar_length)
            bar = '█' * filled + '░' * (bar_length - filled)
            sys.stdout.write(f'\rScanning: [{bar}] {percent}%')
            sys.stdout.flush()

    try:
        results = core.scan_files(
            path=args.path,
            recursive=args.recursive,
            include_hidden=args.all,
            progress_callback=progress if not args.verbose else None
        )

        if not args.verbose:
            print()  # new line after progress bar

        found_count = 0
        for result in results:
            if result['has_hidden_data']:
                found_count += 1
                print(f"\n{Colors.YELLOW}[!] Hidden data found in: {result['file']}{Colors.RESET}")

                if args.verbose:
                    print(f"    Position: {result['marker_position']}")
                    print(f"    Version: {result['version']}")
                    print(f"    Original filename: {result['original_filename']}")
                    print(f"    Hidden data size: {format_size(result['hidden_size'])}")
                    print(f"    File size: {format_size(result['file_size'])}")
            elif args.verbose:
                print(f"[*] Scanning: {result['file']}")

        print(f"\n{Colors.BLUE}[*] Scan complete: {found_count}/{len(results)} file(s) contain hidden data{Colors.RESET}\n")

        return 0

    except Exception as e:
        print(f"{Colors.RED}Error: {e}{Colors.RESET}", file=sys.stderr)
        if args.verbose:
            import traceback
            traceback.print_exc()
        return 1


def main():
    """Main CLI entry point"""
    parser = argparse.ArgumentParser(
        description='Steganography tool - hide encrypted data in files',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  Hide data:
    stego hide photo.jpg secret.txt -o hidden.jpg
    stego hide photo.jpg secrets/ -o hidden.jpg

  Extract data:
    stego show hidden.jpg -o recovered/

  Scan files:
    stego scan hidden.jpg
    stego scan ~/Downloads -r -v
        """
    )

    if not sys.stdout.isatty():
        Colors.disable()

    subparsers = parser.add_subparsers(dest='command', help='Command to execute')

    # Hide command
    hide_parser = subparsers.add_parser('hide',
                                        help='Hide encrypted data in a carrier file',
                                        formatter_class=argparse.RawDescriptionHelpFormatter,
                                        description="""Hide encrypted data in a carrier file.

Examples:
  stego hide photo.jpg secret.txt -o hidden.jpg
  stego hide photo.jpg secrets/ -o hidden.jpg
""")
    hide_parser.add_argument('carrier', type=Path,
                             help='Carrier file (image, video, PDF, etc.)')
    hide_parser.add_argument('data', type=Path,
                             help='File or folder to hide')
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

    if args.command == 'hide':
        return hide_command(args)
    elif args.command == 'show':
        return show_command(args)
    elif args.command == 'scan':
        return scan_command(args)

    return 0


if __name__ == '__main__':
    sys.exit(main())
