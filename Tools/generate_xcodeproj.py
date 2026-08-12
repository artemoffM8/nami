#!/usr/bin/env python3
"""
Генератор NamiApp.xcodeproj.

Проект собирается скриптом, а не руками, поэтому:
  • список файлов всегда совпадает с содержимым диска;
  • merge-конфликты в pbxproj чинятся перегенерацией;
  • добавили файл -> `python3 Tools/generate_xcodeproj.py` -> он в сборке.

Запуск из корня NamiApp:
    python3 Tools/generate_xcodeproj.py

Требуется только Python 3, Xcode не нужен.
"""

from __future__ import annotations

import hashlib
import os
import re
import sys
from pathlib import Path
from typing import NamedTuple

ROOT = Path(__file__).resolve().parent.parent


PROJECT_NAME = "NamiApp"
TARGET_NAME = "NamiApp"
BUNDLE_ID = "com.nami.sudoku"
DEPLOYMENT_TARGET = "18.0"
SWIFT_VERSION = "5.0"   # Swift 6 language mode: поменять на "6.0"
MARKETING_VERSION = "1.0.0"


def existing_development_team() -> str:
    """Команда подписи.

    Берётся из переменной окружения NAMI_DEVELOPMENT_TEAM, а НЕ из текущего
    pbxproj. Раньше значение переносилось из файла в файл, и Team ID автора
    уезжал в репозиторий вместе с проектом — из истории git его потом уже
    не убрать.

    Пустая строка = команда не выбрана: Xcode просто попросит выбрать её при
    первой сборке на устройстве. Для симулятора подпись не нужна вовсе.

        export NAMI_DEVELOPMENT_TEAM=XXXXXXXXXX
        python3 Tools/generate_xcodeproj.py
    """
    return os.environ.get("NAMI_DEVELOPMENT_TEAM", "")


DEVELOPMENT_TEAM = existing_development_team()

LOCAL_PACKAGES = ["NamiDomain", "NamiData", "NamiExperience"]

SOURCE_ROOT = Path("App/Sources")


class TestTarget(NamedTuple):
    """Тестовый таргет проекта.

    Тесты пакетов запускаются двумя разными способами: `swift test` видит их
    по манифесту пакета, `xcodebuild test` — только по pbxproj. Поэтому список
    таргетов лежит здесь, рядом со списком пакетов: пакет со своими тестами,
    забытый в этом списке, даёт зелёный прогон, в котором его тесты просто
    не запускались.
    """

    name: str
    # Каталог с тестами; состав .swift всегда берётся с диска.
    sources: Path
    # Продукты локальных пакетов, к которым линкуется бандл тестов.
    products: list[str]


TEST_TARGETS = [
    TestTarget("NamiDomainTests",
               Path("Packages/NamiDomain/Tests/NamiDomainTests"),
               ["NamiDomain"]),
    TestTarget("NamiDataTests",
               Path("Packages/NamiData/Tests/NamiDataTests"),
               ["NamiData"]),
]

RESOURCES = [
    Path("App/Resources/Assets.xcassets"),
    Path("App/Resources/Puzzles/classic.json"),
    # Required reason API manifest — без него ревью App Store отклоняет билд.
    Path("App/Resources/PrivacyInfo.xcprivacy"),
    # Звуки: список собирается с диска, потому что вариантов round-robin
    # у каждого события своё количество (name.wav, name2.wav, …).
    *[p.relative_to(ROOT) for p in sorted(
        [*(ROOT / "App/Resources/Sounds").glob("*.wav"),
         *(ROOT / "App/Resources/Sounds").glob("*.caf")],
        key=lambda item: item.name)],
]
INFO_PLIST = Path("App/Resources/Info.plist")


# ------------------------------------------------------------------ ids

_used_ids: set[str] = set()


def oid(*parts: str) -> str:
    """Стабильный 24-символьный идентификатор объекта."""
    base = hashlib.sha1("|".join(parts).encode()).hexdigest().upper()[:24]
    candidate = base
    salt = 0
    while candidate in _used_ids:
        salt += 1
        candidate = hashlib.sha1(f"{base}{salt}".encode()).hexdigest().upper()[:24]
    _used_ids.add(candidate)
    return candidate


# ------------------------------------------------------------------ plist writer

class Ref:
    """Ссылка на объект. Рендерится как `ID /* комментарий */` — комментарий
    в pbxproj обязан быть НАСТОЯЩИМ комментарием, а не частью строкового значения."""

    __slots__ = ("oid", "comment")

    def __init__(self, oid_value: str, comment: str = ""):
        self.oid = oid_value
        self.comment = comment

    def render(self) -> str:
        return f"{self.oid} /* {self.comment} */" if self.comment else self.oid


def quote(value: str) -> str:
    safe = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$./")
    if value != "" and all(ch in safe for ch in value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escaped}"'


def render(value, indent: int = 0) -> str:
    if isinstance(value, Ref):
        return value.render()
    pad = "\t" * indent
    inner = "\t" * (indent + 1)
    if isinstance(value, dict):
        if not value:
            return "{\n" + pad + "}"
        lines = ["{"]
        for key in value:
            lines.append(f"{inner}{quote(str(key))} = {render(value[key], indent + 1)};")
        lines.append(pad + "}")
        return "\n".join(lines)
    if isinstance(value, list):
        if not value:
            return "(\n" + pad + ")"
        lines = ["("]
        for item in value:
            lines.append(f"{inner}{render(item, indent + 1)},")
        lines.append(pad + ")")
        return "\n".join(lines)
    return quote(str(value))


# ------------------------------------------------------------------ collect files

def collect_sources() -> list[Path]:
    files = sorted(
        p.relative_to(ROOT)
        for p in (ROOT / SOURCE_ROOT).rglob("*.swift")
    )
    if not files:
        sys.exit(f"Не найдено ни одного .swift в {SOURCE_ROOT}")
    return list(files)


FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".json": "text.json",
    ".plist": "text.plist.xml",
    ".xcprivacy": "text.plist.xml",
    ".xcassets": "folder.assetcatalog",
    ".caf": "audio.caf",
    ".wav": "audio.wav",
    ".ahap": "text.json",
}


def file_type(path: Path) -> str:
    return FILE_TYPES.get(path.suffix, "text")


# ------------------------------------------------------------------ project graph

def build_objects():
    objects: dict[str, dict] = {}

    sources = collect_sources()

    # --- PBXFileReference / PBXBuildFile
    file_refs: dict[Path, str] = {}
    source_build_files: list[str] = []
    resource_build_files: list[str] = []

    for path in sources:
        ref = oid("ref", str(path))
        file_refs[path] = ref
        objects[ref] = {
            "isa": "PBXFileReference",
            "lastKnownFileType": file_type(path),
            "path": path.name,
            "sourceTree": "<group>",
        }
        build = oid("build", str(path))
        objects[build] = {
            "isa": "PBXBuildFile",
            "fileRef": Ref(ref, path.name),
        }
        source_build_files.append(Ref(build, f"{path.name} in Sources"))

    for path in RESOURCES:
        if not (ROOT / path).exists():
            sys.exit(f"Отсутствует ресурс {path}")
        ref = oid("ref", str(path))
        file_refs[path] = ref
        objects[ref] = {
            "isa": "PBXFileReference",
            "lastKnownFileType": file_type(path),
            "path": path.name,
            "sourceTree": "<group>",
        }
        build = oid("build", str(path))
        objects[build] = {
            "isa": "PBXBuildFile",
            "fileRef": Ref(ref, path.name),
        }
        resource_build_files.append(Ref(build, f"{path.name} in Resources"))

    plist_ref = oid("ref", str(INFO_PLIST))
    objects[plist_ref] = {
        "isa": "PBXFileReference",
        "lastKnownFileType": "text.plist.xml",
        "path": INFO_PLIST.name,
        "sourceTree": "<group>",
    }
    file_refs[INFO_PLIST] = plist_ref

    # --- Группы, повторяющие структуру каталогов
    def make_group(dir_path: Path, children_paths: list[Path]) -> str:
        """Рекурсивно строит группу для каталога."""
        subdirs: dict[str, list[Path]] = {}
        direct: list[Path] = []
        for child in children_paths:
            relative = child.relative_to(dir_path)
            if len(relative.parts) == 1:
                direct.append(child)
            else:
                subdirs.setdefault(relative.parts[0], []).append(child)

        children: list[str] = []
        for name in sorted(subdirs):
            child_group = make_group(dir_path / name, subdirs[name])
            children.append(Ref(child_group, name))
        for child in sorted(direct):
            children.append(Ref(file_refs[child], child.name))

        group_id = oid("group", str(dir_path))
        objects[group_id] = {
            "isa": "PBXGroup",
            "children": children,
            "path": dir_path.name,
            "sourceTree": "<group>",
        }
        return group_id

    app_files = sources + RESOURCES + [INFO_PLIST]
    app_group = make_group(Path("App"), app_files)

    # --- Тестовые таргеты: файлы, build-файлы и группа на каждый набор
    test_sources: dict[str, list[Path]] = {}
    test_build_files: dict[str, list[Ref]] = {}
    test_group_refs: list[Ref] = []
    for spec in TEST_TARGETS:
        files = sorted(
            p.relative_to(ROOT) for p in (ROOT / spec.sources).rglob("*.swift")
        )
        if not files:
            sys.exit(f"Не найдено ни одного .swift в {spec.sources}")
        test_sources[spec.name] = files
        test_build_files[spec.name] = []
        for path in files:
            ref = oid("testref", str(path))
            file_refs[path] = ref
            objects[ref] = {
                "isa": "PBXFileReference",
                "lastKnownFileType": "sourcecode.swift",
                "path": path.name,
                "sourceTree": "<group>",
            }
            build = oid("testbuild", str(path))
            objects[build] = {"isa": "PBXBuildFile", "fileRef": Ref(ref, path.name)}
            test_build_files[spec.name].append(Ref(build, f"{path.name} in Sources"))

        test_group = oid("group", "TestsGroup", spec.name)
        objects[test_group] = {
            "isa": "PBXGroup",
            "children": [Ref(file_refs[p], p.name) for p in files],
            "name": spec.name,
            "path": str(spec.sources),
            "sourceTree": "<group>",
        }
        test_group_refs.append(Ref(test_group, spec.name))

    # --- Локальные пакеты: и как ссылки в дереве, и как package references
    packages_children = []
    package_refs = []
    product_deps = []
    for name in LOCAL_PACKAGES:
        folder_ref = oid("pkgfolder", name)
        objects[folder_ref] = {
            "isa": "PBXFileReference",
            "lastKnownFileType": "wrapper",
            "path": name,
            "sourceTree": "<group>",
        }
        packages_children.append(Ref(folder_ref, name))

        pkg_ref = oid("localpkg", name)
        objects[pkg_ref] = {
            "isa": "XCLocalSwiftPackageReference",
            "relativePath": f"Packages/{name}",
        }
        package_refs.append(Ref(pkg_ref, f"XCLocalSwiftPackageReference Packages/{name}"))

        product = oid("product", name)
        objects[product] = {
            "isa": "XCSwiftPackageProductDependency",
            "productName": name,
        }
        product_deps.append(Ref(product, name))

    packages_group = oid("group", "Packages")
    objects[packages_group] = {
        "isa": "PBXGroup",
        "children": packages_children,
        "path": "Packages",
        "sourceTree": "<group>",
    }

    # --- Products
    product_ref = oid("appproduct")
    objects[product_ref] = {
        "isa": "PBXFileReference",
        "explicitFileType": "wrapper.application",
        "includeInIndex": 0,
        "path": f"{TARGET_NAME}.app",
        "sourceTree": "BUILT_PRODUCTS_DIR",
    }
    test_product_refs: dict[str, str] = {}
    for spec in TEST_TARGETS:
        ref = oid("testproduct", spec.name)
        objects[ref] = {
            "isa": "PBXFileReference",
            "explicitFileType": "wrapper.cfbundle",
            "includeInIndex": 0,
            "path": f"{spec.name}.xctest",
            "sourceTree": "BUILT_PRODUCTS_DIR",
        }
        test_product_refs[spec.name] = ref

    products_group = oid("group", "Products")
    objects[products_group] = {
        "isa": "PBXGroup",
        "children": [
            Ref(product_ref, f"{TARGET_NAME}.app"),
            *[Ref(test_product_refs[spec.name], f"{spec.name}.xctest")
              for spec in TEST_TARGETS],
        ],
        "name": "Products",
        "sourceTree": "<group>",
    }

    main_group = oid("group", "main")
    objects[main_group] = {
        "isa": "PBXGroup",
        "children": [
            Ref(app_group, "App"),
            Ref(packages_group, "Packages"),
            *test_group_refs,
            Ref(products_group, "Products"),
        ],
        "sourceTree": "<group>",
    }

    # --- Build phases
    sources_phase = oid("phase", "sources")
    objects[sources_phase] = {
        "isa": "PBXSourcesBuildPhase",
        "buildActionMask": 2147483647,
        "files": source_build_files,
        "runOnlyForDeploymentPostprocessing": 0,
    }
    resources_phase = oid("phase", "resources")
    objects[resources_phase] = {
        "isa": "PBXResourcesBuildPhase",
        "buildActionMask": 2147483647,
        "files": resource_build_files,
        "runOnlyForDeploymentPostprocessing": 0,
    }
    frameworks_phase = oid("phase", "frameworks")
    objects[frameworks_phase] = {
        "isa": "PBXFrameworksBuildPhase",
        "buildActionMask": 2147483647,
        "files": [],
        "runOnlyForDeploymentPostprocessing": 0,
    }

    # --- Build configurations
    common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": SWIFT_VERSION,
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
    }
    project_debug = dict(common, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
        "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    })
    project_release = dict(common, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        "ENABLE_NS_ASSERTIONS": "NO",
        "MTL_ENABLE_DEBUG_INFO": "NO",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": "-O",
        "VALIDATE_PRODUCT": "YES",
    })

    target_common = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": str(INFO_PLIST),
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "MARKETING_VERSION": MARKETING_VERSION,
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        # Пустая строка = команда не выбрана; Xcode тогда просто просит её выбрать.
        "DEVELOPMENT_TEAM": DEVELOPMENT_TEAM,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "TARGETED_DEVICE_FAMILY": "1,2",
    }

    def config(name: str, settings: dict, *key: str) -> str:
        cfg = oid("config", *key, name)
        objects[cfg] = {
            "isa": "XCBuildConfiguration",
            "buildSettings": settings,
            "name": name,
        }
        return cfg

    project_debug_id = config("Debug", project_debug, "project")
    project_release_id = config("Release", project_release, "project")
    target_debug_id = config("Debug", dict(target_common), "target")
    target_release_id = config("Release", dict(target_common), "target")

    project_config_list = oid("configlist", "project")
    objects[project_config_list] = {
        "isa": "XCConfigurationList",
        "buildConfigurations": [
            Ref(project_debug_id, "Debug"),
            Ref(project_release_id, "Release"),
        ],
        "defaultConfigurationIsVisible": 0,
        "defaultConfigurationName": "Release",
    }
    target_config_list = oid("configlist", "target")
    objects[target_config_list] = {
        "isa": "XCConfigurationList",
        "buildConfigurations": [
            Ref(target_debug_id, "Debug"),
            Ref(target_release_id, "Release"),
        ],
        "defaultConfigurationIsVisible": 0,
        "defaultConfigurationName": "Release",
    }

    # --- Target
    target_id = oid("target", TARGET_NAME)
    objects[target_id] = {
        "isa": "PBXNativeTarget",
        "buildConfigurationList": Ref(target_config_list, f"Build configuration list for PBXNativeTarget \"{TARGET_NAME}\""),
        "buildPhases": [
            Ref(sources_phase, "Sources"),
            Ref(frameworks_phase, "Frameworks"),
            Ref(resources_phase, "Resources"),
        ],
        "buildRules": [],
        "dependencies": [],
        "name": TARGET_NAME,
        "packageProductDependencies": product_deps,
        "productName": TARGET_NAME,
        "productReference": Ref(product_ref, f"{TARGET_NAME}.app"),
        "productType": "com.apple.product-type.application",
    }

    # --- Тестовые таргеты
    # Logic tests: без TEST_HOST и BUNDLE_LOADER — ни доменный слой, ни
    # хранилище не требуют запущенного приложения (ModelContainer поднимается
    # в памяти), поэтому тесты идут быстрее и стабильнее.
    test_target_ids: dict[str, str] = {}
    for spec in TEST_TARGETS:
        test_sources_phase = oid("phase", "testsources", spec.name)
        objects[test_sources_phase] = {
            "isa": "PBXSourcesBuildPhase",
            "buildActionMask": 2147483647,
            "files": test_build_files[spec.name],
            "runOnlyForDeploymentPostprocessing": 0,
        }
        test_frameworks_phase = oid("phase", "testframeworks", spec.name)
        objects[test_frameworks_phase] = {
            "isa": "PBXFrameworksBuildPhase",
            "buildActionMask": 2147483647,
            "files": [],
            "runOnlyForDeploymentPostprocessing": 0,
        }

        test_deps = []
        for product in spec.products:
            dep = oid("testproductdep", spec.name, product)
            objects[dep] = {
                "isa": "XCSwiftPackageProductDependency",
                "productName": product,
            }
            test_deps.append(Ref(dep, product))

        test_settings = {
            "CODE_SIGN_STYLE": "Automatic",
            "CURRENT_PROJECT_VERSION": "1",
            "GENERATE_INFOPLIST_FILE": "YES",
            "MARKETING_VERSION": MARKETING_VERSION,
            # У каждого бандла свой идентификатор: два тестовых таргета с
            # одинаковым bundle id симулятор считает одним и тем же бандлом.
            "PRODUCT_BUNDLE_IDENTIFIER": f"{BUNDLE_ID}.{spec.name}",
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "SWIFT_EMIT_LOC_STRINGS": "NO",
            "TARGETED_DEVICE_FAMILY": "1,2",
        }

        test_debug_id = config("Debug", dict(test_settings), "testtarget", spec.name)
        test_release_id = config("Release", dict(test_settings), "testtarget", spec.name)
        test_config_list = oid("configlist", "testtarget", spec.name)
        objects[test_config_list] = {
            "isa": "XCConfigurationList",
            "buildConfigurations": [
                Ref(test_debug_id, "Debug"),
                Ref(test_release_id, "Release"),
            ],
            "defaultConfigurationIsVisible": 0,
            "defaultConfigurationName": "Release",
        }

        test_target_id = oid("target", spec.name)
        objects[test_target_id] = {
            "isa": "PBXNativeTarget",
            "buildConfigurationList": Ref(
                test_config_list,
                f"Build configuration list for PBXNativeTarget \"{spec.name}\""
            ),
            "buildPhases": [
                Ref(test_sources_phase, "Sources"),
                Ref(test_frameworks_phase, "Frameworks"),
            ],
            "buildRules": [],
            "dependencies": [],
            "name": spec.name,
            "packageProductDependencies": test_deps,
            "productName": spec.name,
            "productReference": Ref(test_product_refs[spec.name], f"{spec.name}.xctest"),
            "productType": "com.apple.product-type.bundle.unit-test",
        }
        test_target_ids[spec.name] = test_target_id

    # --- Project
    project_id = oid("project", PROJECT_NAME)
    objects[project_id] = {
        "isa": "PBXProject",
        "attributes": {
            "BuildIndependentTargetsInParallel": 1,
            "LastSwiftUpdateCheck": 1600,
            "LastUpgradeCheck": 1600,
            "TargetAttributes": {
                target_id: {"CreatedOnToolsVersion": "16.0"},
                **{test_target_ids[spec.name]: {"CreatedOnToolsVersion": "16.0"}
                   for spec in TEST_TARGETS},
            },
        },
        "buildConfigurationList": Ref(project_config_list, f"Build configuration list for PBXProject \"{PROJECT_NAME}\""),
        "compatibilityVersion": "Xcode 14.0",
        "developmentRegion": "ru",
        "hasScannedForEncodings": 0,
        "knownRegions": ["ru", "en", "Base"],
        "mainGroup": main_group,
        "packageReferences": package_refs,
        "productRefGroup": Ref(products_group, "Products"),
        "projectDirPath": "",
        "projectRoot": "",
        "targets": [
            Ref(target_id, TARGET_NAME),
            *[Ref(test_target_ids[spec.name], spec.name) for spec in TEST_TARGETS],
        ],
    }

    return objects, project_id, target_id, test_target_ids, len(sources), test_sources


# ------------------------------------------------------------------ scheme

SCHEME_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference
               BuildableIdentifier="primary"
               BlueprintIdentifier="{target_id}"
               BuildableName="{target}.app"
               BlueprintName="{target}"
               ReferencedContainer="container:{project}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
{test_build_entries}      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
      <Testables>
{testables}      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference
            BuildableIdentifier="primary"
            BlueprintIdentifier="{target_id}"
            BuildableName="{target}.app"
            BlueprintName="{target}"
            ReferencedContainer="container:{project}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         <BuildableReference
            BuildableIdentifier="primary"
            BlueprintIdentifier="{target_id}"
            BuildableName="{target}.app"
            BlueprintName="{target}"
            ReferencedContainer="container:{project}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"></ArchiveAction>
</Scheme>
"""

# Блоки на каждый тестовый таргет. Таргет, которого нет в <Testables>,
# собирается, но `xcodebuild test` его не запускает — прогон зелёный,
# а тесты не выполнялись.
SCHEME_TEST_BUILD_ENTRY = """         <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">
            <BuildableReference
               BuildableIdentifier="primary"
               BlueprintIdentifier="{test_target_id}"
               BuildableName="{test_target}.xctest"
               BlueprintName="{test_target}"
               ReferencedContainer="container:{project}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
"""

SCHEME_TESTABLE = """         <TestableReference skipped="NO" parallelizable="YES">
            <BuildableReference
               BuildableIdentifier="primary"
               BlueprintIdentifier="{test_target_id}"
               BuildableName="{test_target}.xctest"
               BlueprintName="{test_target}"
               ReferencedContainer="container:{project}.xcodeproj">
            </BuildableReference>
         </TestableReference>
"""


def scheme_body(target_id: str, test_target_ids: dict[str, str]) -> str:
    """Схема со всеми тестовыми таргетами в сборке и в прогоне."""
    def blocks(template: str) -> str:
        return "".join(
            template.format(test_target_id=test_target_ids[spec.name],
                            test_target=spec.name,
                            project=PROJECT_NAME)
            for spec in TEST_TARGETS
        )

    return SCHEME_TEMPLATE.format(
        target_id=target_id,
        target=TARGET_NAME,
        project=PROJECT_NAME,
        test_build_entries=blocks(SCHEME_TEST_BUILD_ENTRY),
        testables=blocks(SCHEME_TESTABLE),
    )


# ------------------------------------------------------------------ main

def main() -> None:
    objects, project_id, target_id, test_target_ids, source_count, test_sources = build_objects()

    document = {
        "archiveVersion": 1,
        "classes": {},
        "objectVersion": 56,
        "objects": objects,
        "rootObject": Ref(project_id, "Project object"),
    }

    project_dir = ROOT / f"{PROJECT_NAME}.xcodeproj"
    # Перезаписываем файлы на месте: удалять каталог не нужно и небезопасно,
    # если Xcode держит его открытым.
    (project_dir / "xcshareddata" / "xcschemes").mkdir(parents=True, exist_ok=True)

    body = "// !$*UTF8*$!\n" + render(document) + "\n"
    (project_dir / "project.pbxproj").write_text(body, encoding="utf-8")

    (project_dir / "xcshareddata" / "xcschemes" / f"{PROJECT_NAME}.xcscheme").write_text(
        scheme_body(target_id, test_target_ids),
        encoding="utf-8",
    )

    workspace_dir = project_dir / "project.xcworkspace"
    workspace_dir.mkdir(parents=True, exist_ok=True)
    # Workspace-файл создаётся один раз: Xcode держит его открытым и на каждую
    # перезапись показывает диалог «файл изменён другим приложением».
    workspace_file = workspace_dir / "contents.xcworkspacedata"
    if not workspace_file.exists():
        workspace_file.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<Workspace version="1.0">\n'
            '   <FileRef location="self:"></FileRef>\n'
            '</Workspace>\n',
            encoding="utf-8",
        )
    shared = workspace_dir / "xcshareddata"
    shared.mkdir(parents=True, exist_ok=True)
    (shared / "IDEWorkspaceChecks.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n<dict>\n'
        '\t<key>IDEDidComputeMac32BitWarning</key>\n\t<true/>\n'
        '</dict>\n</plist>\n',
        encoding="utf-8",
    )

    print(f"Готово: {project_dir.relative_to(ROOT)}")
    print(f"  Swift-файлов в таргете: {source_count}")
    for spec in TEST_TARGETS:
        print(f"  Тестовых файлов в {spec.name}: {len(test_sources[spec.name])}")
    print(f"  Локальных пакетов: {', '.join(LOCAL_PACKAGES)}")
    print(f"  Deployment target: iOS {DEPLOYMENT_TARGET}, Swift {SWIFT_VERSION}")


if __name__ == "__main__":
    main()
