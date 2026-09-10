import argparse
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile

DEPENDENCIES = (
    ("flatbuffers", "https://github.com/google/flatbuffers.git", "25.2.10",
     "flatbuffers-1c514626e83c20fffa8557e75641848e1e15cd5e",
     ("Package.swift", "LICENSE", "swift/Sources")),
    ("swift-atomics", "https://github.com/apple/swift-atomics.git", "1.3.0",
     "swift-atomics-b601256eab081c0f92f059e12818ac1d4f178ff7",
     ("Package.swift", "LICENSE.txt", "Sources", "Tests")),
)
PACKAGE_PREFIX = "swift/FieldSurvey/LocalPackages/arrow-swift/"


def extract_source(archive, destination, prefix, selected):
    with tarfile.open(archive, "r:gz") as source:
        members = source.getmembers()
        seen = set()
        accepted = []
        for member in members:
            path = PurePosixPath(member.name)
            if (path.is_absolute() or ".." in path.parts or "\\" in member.name
                    or not path.parts or path.parts[0] != prefix
                    or path in seen):
                raise ValueError("Unsafe dependency archive entry")
            seen.add(path)
            relative = "/".join(path.parts[1:])
            if not any(relative == item or relative.startswith(item + "/") for item in selected):
                continue
            if not (member.isfile() or member.isdir()):
                raise ValueError("Unsafe dependency archive entry")
            accepted.append(member)
        for member in accepted:
            target = destination.joinpath(*PurePosixPath(member.name).parts[1:])
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as src, target.open("wb") as dst:
                    shutil.copyfileobj(src, dst)


def stage_files(resolver, names, destination, prefix):
    for name in names:
        relative = name.split("/", 1)[1]
        if not relative.startswith(prefix):
            raise ValueError("Unexpected declared Swift input")
        target = destination / relative[len(prefix):]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(resolver.Rlocation(name), target)


def main():
    from python.runfiles import runfiles

    parser = argparse.ArgumentParser()
    parser.add_argument("--package", nargs="+", required=True)
    parser.add_argument("--flatbuffers", required=True)
    parser.add_argument("--atomics", required=True)
    parser.add_argument("--upstream", nargs="+", default=[])
    parser.add_argument("--ios", action="store_true")
    args = parser.parse_args()
    resolver = runfiles.Create()
    work = Path(os.environ["TEST_TMPDIR"]) / "arrow-regression"
    work.mkdir()
    package = work / "Arrow"
    stage_files(resolver, args.package, package, PACKAGE_PREFIX)
    manifest_path = package / "Package.swift"
    manifest = manifest_path.read_text()
    for (name, url, version, prefix, selected), archive in zip(
            DEPENDENCIES, (args.flatbuffers, args.atomics)):
        extract_source(resolver.Rlocation(archive), work / name, prefix, selected)
        production = f'.package(url: "{url}", exact: "{version}")'
        if manifest.count(production) != 1:
            raise ValueError("Production dependency differs from the reviewed exact pin")
        manifest = manifest.replace(production, f'.package(path: "../{name}")')
    if args.upstream:
        stage_files(resolver, args.upstream, package / "Tests/UpstreamArrowTests",
                    "Tests/ArrowTests/")
        marker = '    targets: [\n'
        if manifest.count(marker) != 1:
            raise ValueError("Unexpected package target declaration")
        manifest = manifest.replace(marker, marker +
            '        .testTarget(name: "UpstreamArrowTests", dependencies: ["Arrow", "ArrowC"]),\n')
    manifest_path.write_text(manifest)
    env = dict(os.environ)
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    if not Path(env["DEVELOPER_DIR"]).is_dir():
        raise RuntimeError("Requested Xcode DEVELOPER_DIR is unavailable")
    env["CLANG_MODULE_CACHE_PATH"] = str(work / "clang-cache")
    env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(work / "module-cache")
    sdk_name = "iphonesimulator" if args.ios else "macosx"
    sdk = subprocess.check_output(
        ["/usr/bin/xcrun", "--sdk", sdk_name, "--show-sdk-path"], env=env, text=True).strip()
    if not sdk or not Path(sdk).is_dir():
        raise RuntimeError("Requested Xcode SDK is unavailable")
    command = ["/usr/bin/xcrun", "swift", "build" if args.ios else "test",
               "--package-path", str(package), "--scratch-path", str(work / "build"),
               "--cache-path", str(work / "cache"), "--disable-sandbox",
               "--disable-automatic-resolution", "--sdk", sdk]
    if args.ios:
        command += ["--triple", "arm64-apple-ios26.2-simulator", "--target", "Arrow"]
    else:
        command += ["--skip", "IPCFileReaderTests.testFile"]
        print("Running synthetic compatibility and 43 upstream core tests; excluding five external-file tests", flush=True)
    subprocess.run(command, env=env, check=True)


if __name__ == "__main__":
    main()
