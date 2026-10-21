"""Windows path compatibility for Qwen's legacy DyNet dependency."""
import os
import sys


def prepare_import_paths():
    """Keep Python imports on ASCII aliases without moving/copying runtime data."""
    if os.name != 'nt':
        return
    import ctypes
    from ctypes import wintypes as w
    get_short = ctypes.WinDLL('kernel32', use_last_error=True).GetShortPathNameW
    get_short.argtypes = [w.LPCWSTR, w.LPWSTR, w.DWORD]
    get_short.restype = w.DWORD
    paths = []
    for value in sys.path:
        if value and not value.isascii() and os.path.exists(value):
            output = ctypes.create_unicode_buffer(32768)
            count = get_short(value, output, len(output))
            if not 0 < count < len(output) or not output.value.isascii():
                raise RuntimeError('Qwen DyNet requires an ASCII runtime path or Windows 8.3 short names; choose an ASCII component destination.')
            value = output.value
        paths.append(value)
    sys.path[:] = paths
