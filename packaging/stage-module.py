"""Copy an administrator-approved module into a private staging directory."""

import hashlib
import os
from pathlib import Path
import stat
import sys


def stage(source, destination, uid, expected):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    with os.fdopen(os.open(source, flags), "rb") as artifact:
        metadata = os.fstat(artifact.fileno())
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid not in (0, uid)
                or metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH)):
            raise ValueError(
                f"Module must be a regular file owned by the installing user or root "
                f"and not group/world-writable (chmod 0644): {source}"
            )
        digest = hashlib.sha256()
        target = Path(destination)
        with target.open("xb") as staged:
            while chunk := artifact.read(1024 * 1024):
                digest.update(chunk)
                staged.write(chunk)
        if digest.hexdigest() != expected:
            target.unlink(missing_ok=True)
            raise ValueError(f"Module differs from the approved SHA-256: {source}")


if __name__ == "__main__":
    try:
        source, destination, uid, expected = sys.argv[1:]
        stage(source, destination, int(uid), expected.lower())
    except (OSError, ValueError) as error:
        sys.exit(str(error))
