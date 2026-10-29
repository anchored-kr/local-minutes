#!/usr/bin/env python3
"""engine/bin 의 실행 파일 · ggml 백엔드(.so)가 쓰는 Homebrew 라이브러리를 engine/lib 로 모으고,
참조를 @rpath 로 바꾼다. 받는 사람 맥에 Homebrew 가 없어도 돌게 하려는 것.

사용: bundle_dylibs.py <engine 폴더>
"""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

SEARCH = [Path(p) for p in ("/opt/homebrew/opt/whisper-cpp/lib", "/opt/homebrew/opt/llama.cpp/lib",
                            "/opt/homebrew/opt/ggml/lib", "/opt/homebrew/lib")]
SYSTEM = ("/usr/lib/", "/System/")


def otool_deps(f):
    out = subprocess.run(["otool", "-L", str(f)], capture_output=True, text=True, check=True).stdout
    return [m.group(1) for m in re.finditer(r"^\s+(\S+) \(compatibility", out, re.M)]


def resolve(ref):
    if ref.startswith("@rpath/"):
        name = ref.split("/", 1)[1]
        for d in SEARCH:
            if (d / name).exists():
                return (d / name).resolve()
        raise SystemExit(f"찾지 못함: {ref}")
    return Path(ref).resolve()


def tool(*args):
    subprocess.run(["install_name_tool", *args], check=True, capture_output=True)


def main():
    engine = Path(sys.argv[1])
    lib = engine / "lib"
    lib.mkdir(exist_ok=True)
    todo = [p for p in (engine / "bin").iterdir() if p.is_file()]
    done = set()
    while todo:
        f = todo.pop()
        if f in done:
            continue
        done.add(f)
        os.chmod(f, 0o755)
        for ref in otool_deps(f):
            if ref.startswith(SYSTEM) or ref.startswith(("@loader_path", "@executable_path")):
                continue
            name = Path(ref).name
            if f.parent == lib and name == f.name:
                continue  # 자기 자신(LC_ID_DYLIB)
            if ref.startswith("@rpath/") and (lib / name).exists() and lib / name in done:
                continue
            dst = lib / name
            if not dst.exists():
                shutil.copy2(resolve(ref), dst)
                os.chmod(dst, 0o755)
                tool("-id", f"@rpath/{name}", str(dst))
                todo.append(dst)
            if ref != f"@rpath/{name}":
                tool("-change", ref, f"@rpath/{name}", str(f))
    # rpath: bin/* → @loader_path/../lib, lib/* → @loader_path
    for f in done:
        rp = "@loader_path" if f.parent == lib else "@loader_path/../lib"
        out = subprocess.run(["otool", "-l", str(f)], capture_output=True, text=True).stdout
        existing = re.findall(r"path (\S+) \(offset", out)
        for e in existing:
            if e != rp:
                tool("-delete_rpath", e, str(f))
        if rp not in existing:
            tool("-add_rpath", rp, str(f))
    left = [(str(f), r) for f in done for r in otool_deps(f) if r.startswith("/opt/homebrew")]
    if left:
        raise SystemExit(f"Homebrew 참조가 남음: {left}")
    print(f"라이브러리 {len(list(lib.iterdir()))}개를 engine/lib 로 모음")


if __name__ == "__main__":
    main()
