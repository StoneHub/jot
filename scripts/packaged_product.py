"""Keep a supplied bundle's contents within the product being verified and installed."""
import os
from pathlib import Path
import stat


def validate_product_paths(product, container=None):
    product = Path(product)
    if product.is_symlink() or not product.is_dir():
        raise SystemExit('Packaged Jot.app must be a real directory, not a symlink.')
    bundle = product.resolve(strict=True)
    if container is not None and bundle.parent != Path(container).resolve(strict=True):
        raise SystemExit('Packaged Jot.app is outside its extraction directory.')
    # Do not follow directory symlinks while walking. Their real targets are visited
    # as ordinary bundle entries, and every link is checked against the same root.
    def unreadable(error):
        raise SystemExit(f'Cannot inspect packaged product: {error.filename}')

    for directory, directories, files in os.walk(product, followlinks=False, onerror=unreadable):
        for name in directories + files:
            path = Path(directory) / name
            try:
                target = path.resolve(strict=True)
            except (OSError, RuntimeError):
                raise SystemExit(f'Invalid packaged product path: {path}') from None
            if target != bundle and bundle not in target.parents:
                raise SystemExit(f'Packaged product path escapes Jot.app: {path}')
            mode = path.lstat().st_mode
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode) or stat.S_ISLNK(mode)):
                raise SystemExit(f'Unsupported packaged product entry: {path}')
    return product
