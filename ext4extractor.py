import sys
import os
from ext4 import Volume, InodeType

def extract_ext4_contents(image_path, output_directory):
    """
    Extracts files and directories from an ext4 image to a specified output directory.

    Args:
        image_path (str): Path to the input .img file (e.g., system.img).
        output_directory (str): Path to the directory where contents will be extracted.
    """
    if not os.path.exists(image_path):
        print(f"Error: Image file not found at '{image_path}'", file=sys.stderr)
        sys.exit(1)

    print(f"Attempting to extract '{image_path}' to '{output_directory}'...")

    os.makedirs(output_directory, exist_ok=True)

    try:
        with open(image_path, "rb") as f:
            volume = Volume(f, offset=0)
            root_inode = volume.root

            _recursive_extract(volume, root_inode, b'/', output_directory)
            
        print(f"Successfully extracted '{image_path}' to '{output_directory}'")

    except Exception as e:
        print(f"Fatal error during extraction of '{image_path}': {e}", file=sys.stderr)
        sys.exit(1)

def _recursive_extract(volume, current_inode, current_fs_path_bytes, target_host_path):
    """
    Recursively extracts directory contents, files, and symlinks.
    Internal helper function.
    """
    try:
        if current_inode.is_dir:
            print(f"  Creating directory: {target_host_path}")
            os.makedirs(target_host_path, exist_ok=True)

            for entry_name_bytes, entry_inode_idx, entry_type in current_inode.opendir():
                if entry_name_bytes in (b'.', b'..'):
                    continue

                entry_name_str = entry_name_bytes.decode('utf-8', errors='ignore')

                child_inode = volume.get_inode(entry_inode_idx, entry_type)

                child_fs_path_bytes = os.path.join(current_fs_path_bytes, entry_name_bytes)
                child_target_host_path = os.path.join(target_host_path, entry_name_str)

                _recursive_extract(volume, child_inode, child_fs_path_bytes, child_target_host_path)

        elif current_inode.is_file:
            print(f"  Extracting file: {target_host_path}")
            with open(target_host_path, "wb") as f_out:
                f_out.write(current_inode.open().read())

        elif current_inode.is_symlink:
            print(f"  Creating symlink: {target_host_path}")
            try:
                link_target = current_inode.open().read().decode('utf-8', errors='ignore')
                if os.path.exists(target_host_path) or os.path.islink(target_host_path):
                    os.unlink(target_host_path)
                os.symlink(link_target, target_host_path)
            except Exception as e:
                print(f"Warning: Could not create symlink {target_host_path} -> {link_target}: {e}", file=sys.stderr)
        else:
            print(f"  Skipping unsupported inode type ({current_inode.file_type}): {target_host_path}", file=sys.stderr)
    except Exception as e:
        print(f"Error processing {target_host_path}: {e}", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 ext4extractor.py <image_path> <output_directory>")
        sys.exit(1)

    image_path = sys.argv[1]
    output_directory = sys.argv[2]

    extract_ext4_contents(image_path, output_directory)
