import sys
import os
from ext4 import Volume

def extract_dir(volume, inode, outdir):
    if not os.path.exists(outdir):
        os.makedirs(outdir, exist_ok=True)
    for entry_name, inode_idx in inode.opendir():
        if entry_name in (b'.', b'..'):
            continue
        name = entry_name.decode(errors='ignore')
        child_inode = volume.get_inode(inode_idx)
        outpath = os.path.join(outdir, name)
        if child_inode.is_dir:
            extract_dir(volume, child_inode, outpath)
        elif child_inode.is_file:
            with open(outpath, 'wb') as f:
                f.write(child_inode.open().read())
        elif child_inode.is_symlink:
            target = child_inode.open().read().decode(errors='ignore')
            try:
                os.symlink(target, outpath)
            except Exception:
                pass

def main():
    if len(sys.argv) != 3:
        print(f"Usage: python3 {sys.argv[0]} IMAGE OUTDIR")
        sys.exit(1)
    image, outdir = sys.argv[1], sys.argv[2]
    with open(image, 'rb') as f:
        v = Volume(f)
        extract_dir(v, v.root, outdir)

if __name__ == '__main__':
    main()
