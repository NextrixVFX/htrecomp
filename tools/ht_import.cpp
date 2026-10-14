// Headless game-package importer.
//
// Does what the first-run wizard in src/ht_setup.cpp does, minus the GUI:
// unpacks an Xbox 360 STFS content package into a game_data folder.
//
// Two reasons this exists:
//
//   1. src/ht_setup.cpp's PickFile() and AskYesNo() are stubbed to return
//      false outside _WIN32, so the wizard cannot run at all on macOS or
//      Linux. This gives those platforms a working import path.
//   2. Even on Windows the wizard needs someone to click a file dialog, which
//      rules it out for scripted setup and CI.
//
// Build:
//   cmake --build <dir> --target ht_import
//
// Use:
//   ht_import <package-file> [dest-dir]
//
// dest-dir defaults to ./game_data. The package is the file whose name is a
// long string of hex characters with no extension - NOT a default.xex. If you
// point this at a raw default.xex it will tell you so rather than guess.
//
// This does not convert default.xex. Check the exit message: a retail package
// carries an encrypted, LZX-compressed executable, and the game needs it
// unpacked. See the README for the xextool invocation.

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <span>
#include <string>
#include <vector>

#include <rex/filesystem.h>
#include <rex/filesystem/devices/stfs_container_device.h>
#include <rex/filesystem/entry.h>
#include <rex/filesystem/file.h>
#include <rex/logging.h>

namespace {

using rex::X_STATUS;

// Matches src/ht_setup.cpp: the package is ~460 MB and some entries inside it
// are large, so read in chunks rather than whole files.
constexpr size_t kCopyChunk = 1u << 20;

int g_files = 0;
uint64_t g_bytes = 0;

bool WriteEntry(rex::filesystem::Entry* entry, const std::filesystem::path& dest) {
  rex::filesystem::File* file = nullptr;
  if (entry->Open(rex::filesystem::FileAccess::kGenericRead, &file) != X_STATUS_SUCCESS || !file) {
    std::fprintf(stderr, "error: could not open '%s' inside the package\n", entry->name().c_str());
    return false;
  }

  std::FILE* out = std::fopen(dest.string().c_str(), "wb");
  if (!out) {
    std::fprintf(stderr, "error: could not create '%s'\n", dest.string().c_str());
    file->Destroy();
    return false;
  }

  std::vector<uint8_t> chunk(kCopyChunk);
  size_t offset = 0;
  const size_t total = entry->size();
  bool ok = true;
  while (offset < total) {
    const size_t want = (total - offset) < kCopyChunk ? (total - offset) : kCopyChunk;
    size_t got = 0;
    if (file->ReadSync(std::span<uint8_t>(chunk.data(), want), offset, &got) != X_STATUS_SUCCESS ||
        got == 0) {
      std::fprintf(stderr, "error: read failed in '%s' at offset %zu\n", entry->name().c_str(),
                   offset);
      ok = false;
      break;
    }
    if (std::fwrite(chunk.data(), 1, got, out) != got) {
      std::fprintf(stderr, "error: write failed for '%s' - is the disk full?\n",
                   dest.string().c_str());
      ok = false;
      break;
    }
    offset += got;
  }

  std::fclose(out);
  file->Destroy();
  if (ok) {
    g_bytes += offset;
  } else {
    std::error_code ec;
    std::filesystem::remove(dest, ec);
  }
  return ok;
}

bool ExtractTree(rex::filesystem::Entry* entry, const std::filesystem::path& dest,
                 const std::string& prefix) {
  std::error_code ec;
  for (const auto& child : entry->children()) {
    const auto target = dest / child->name();
    const std::string rel = prefix.empty() ? child->name() : prefix + "/" + child->name();
    if (child->attributes() & rex::filesystem::kFileAttributeDirectory) {
      std::printf("  dir   %s\n", rel.c_str());
      std::filesystem::create_directories(target, ec);
      if (!ExtractTree(child.get(), target, rel)) {
        return false;
      }
    } else {
      std::printf("  file  %-56s %10zu\n", rel.c_str(), size_t(child->size()));
      std::filesystem::create_directories(dest, ec);
      if (!WriteEntry(child.get(), target)) {
        return false;
      }
      ++g_files;
    }
  }
  return true;
}

// Reads the XEX file-format optional header the same way ht_setup.cpp's
// ValidateXexUsable does, so this tool reports the same verdict the game will.
// encryption != 0 or compression == 2 means it still needs converting.
bool ReadXexFormat(const std::filesystem::path& xex, uint16_t* encryption, uint16_t* compression) {
  std::FILE* f = std::fopen(xex.string().c_str(), "rb");
  if (!f) {
    return false;
  }
  auto be32 = [](const uint8_t* p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | uint32_t(p[3]);
  };
  uint8_t head[24];
  bool ok = std::fread(head, 1, sizeof(head), f) == sizeof(head);
  if (ok) {
    ok = std::memcmp(head, "XEX2", 4) == 0;
  }
  if (ok) {
    const uint32_t count = be32(head + 20);
    ok = false;
    for (uint32_t i = 0; i < count && i < 256; ++i) {
      uint8_t ent[8];
      if (std::fseek(f, 24 + long(i) * 8, SEEK_SET) != 0 ||
          std::fread(ent, 1, sizeof(ent), f) != sizeof(ent)) {
        break;
      }
      // XEX_HEADER_FILE_FORMAT_INFO. Match on the top 24 bits, as
      // src/ht_setup.cpp does: the real key is 0x000003FF, where the 0xFF low
      // byte marks a variable-size header whose value is a file offset. An
      // exact compare against 0x00000003 silently matches nothing.
      if ((be32(ent) >> 8) != 0x000003u) {
        continue;
      }
      uint8_t info[8];
      if (std::fseek(f, long(be32(ent + 4)), SEEK_SET) != 0 ||
          std::fread(info, 1, sizeof(info), f) != sizeof(info)) {
        break;
      }
      *encryption = uint16_t((info[4] << 8) | info[5]);
      *compression = uint16_t((info[6] << 8) | info[7]);
      ok = true;
      break;
    }
  }
  std::fclose(f);
  return ok;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr,
                 "usage: ht_import <package-file> [dest-dir]\n"
                 "\n"
                 "  package-file  the Xbox 360 content package - the file whose name is a\n"
                 "                long string of hex characters with no extension\n"
                 "  dest-dir      where to unpack (default: ./game_data)\n");
    return 2;
  }

  const std::filesystem::path package = argv[1];
  const std::filesystem::path dest = argc >= 3 ? argv[2] : "game_data";

  std::error_code ec;
  if (!std::filesystem::exists(package, ec)) {
    std::fprintf(stderr, "error: '%s' does not exist\n", package.string().c_str());
    return 1;
  }

  if (!rex::filesystem::StfsContainerDevice::ReadPackageHeader(package)) {
    std::fprintf(stderr,
                 "error: '%s' is not an Xbox 360 content package.\n"
                 "\n"
                 "Expected the package itself, whose name is a long string of hex\n"
                 "characters with no file extension. A bare default.xex is the file\n"
                 "*inside* such a package, not the package - this tool cannot use one.\n",
                 package.string().c_str());
    return 1;
  }

  rex::filesystem::StfsContainerDevice device("\\SETUP", package);
  if (!device.Initialize()) {
    std::fprintf(stderr, "error: that package could not be opened; it may be incomplete\n");
    return 1;
  }

  auto* root = device.ResolvePath("");
  if (!root) {
    std::fprintf(stderr, "error: that package opened but appears to be empty\n");
    return 1;
  }

  std::printf("unpacking '%s' -> '%s'\n", package.string().c_str(), dest.string().c_str());
  std::filesystem::create_directories(dest, ec);

  if (!ExtractTree(root, dest, "")) {
    std::fprintf(stderr,
                 "\nerror: extraction failed part-way through. The partly written files\n"
                 "were left in place so you can inspect them; delete '%s' before\n"
                 "trying again.\n",
                 dest.string().c_str());
    return 1;
  }

  std::printf("\nunpacked %d file(s), %.1f MB\n", g_files, double(g_bytes) / 1048576.0);

  // The game needs default.xex at the top level of game_data. Say so plainly
  // rather than leaving a folder that fails at the title screen.
  const auto xex = dest / "default.xex";
  if (!std::filesystem::exists(xex, ec)) {
    std::printf(
        "\nWARNING: no default.xex at the top level of '%s'.\n"
        "The game requires one there. Check the listing above for where it landed.\n",
        dest.string().c_str());
    return 0;
  }

  uint16_t encryption = 0, compression = 0;
  if (!ReadXexFormat(xex, &encryption, &compression)) {
    std::printf("\ndefault.xex present; could not read its format header.\n");
    return 0;
  }

  std::printf("\ndefault.xex: encryption=%u compression=%u\n", encryption, compression);
  if (encryption == 0 && compression != 2) {
    std::printf("Already in a runnable form. Nothing further to do.\n");
    return 0;
  }

  std::printf(
      "\nThis still needs converting before the game can run. Unconverted, the\n"
      "game reaches the title screen and closes when you press Start.\n"
      "\n"
      "  xextool -c u -e u -o default.xex default.xex\n"
      "\n"
      "Run that on the file at:\n  %s\n",
      xex.string().c_str());
  return 0;
}
