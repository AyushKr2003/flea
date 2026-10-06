// Which archive formats this box can actually write and read, probed once at startup, and the argv
// each tool needs. The jobs themselves are archiveops.rs and reading an index is archivelist.rs.
use crate::backend::archivespec::{seven_spec, tar_spec, ListSpec};
use std::path::Path;

const BSDTAR: &str = "bsdtar";
const SEVENZIP: &str = "7z";

// The formats bsdtar writes on this box, in the order the submenu offers them.
const TAR_FORMATS: &[&str] = &["zip", "tar", "tar.gz", "tar.bz2", "tar.xz", "tar.zst"];
const SEVENZIP_FORMAT: &str = "7z";

// Either tool reads a .zip and a .rar, which is what a 7z-only box can still extract.
const ZIP_SUFFIXES: &[&str] = &[".zip", ".rar"];
// Tar stays on bsdtar: `7z x` on a .tar.gz writes the inner .tar, not the files.
const TAR_SUFFIXES: &[&str] = &[".tar.zst", ".tar.bz2", ".tar.gz", ".tar.xz", ".tgz", ".tar"];
// Archives040: packages and disk images list and extract through 7z, longest form first so a
// compound name still matches its own tail before a shorter one could.
const SEVEN_SUFFIXES: &[&str] = &[".appimage", ".cpio", ".cab", ".jar", ".apk", ".rpm", ".deb", ".iso"];
// A disk image lists only: extracting an ISO is refused by building nothing, the way a missing
// tool is, so the client never starts a job for it.
const LIST_ONLY_SUFFIXES: &[&str] = &[".iso"];

// Which program reads one archive, decided from the name's own extension and what this box has.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Reader {
    Bsdtar,
    SevenZip,
}

pub struct Formats {
    names: Vec<String>,
    have_bsdtar: bool,
    have_7z: bool,
    // Test seam: with the probe set, compress() itself runs the RLIMIT_CPU check (see K1).
    #[cfg(test)]
    probe: bool,
    // Test seam: with the block set, compress() itself runs a tool that stays alive to be cancelled.
    #[cfg(test)]
    block: bool,
}

fn on_path(prog: &str) -> bool {
    let path = std::env::var("PATH").unwrap_or_default();
    path.split(':')
        .filter(|d| !d.is_empty())
        .any(|d| Path::new(d).join(prog).is_file())
}

impl Formats {
    pub fn probe() -> Formats {
        Formats::from_tools(on_path(BSDTAR), on_path(SEVENZIP))
    }

    // Nothing writes rar here: WinRAR's own tool is the only thing on Linux that does, it is not free
    // software and it is in no Arch repository, so the compress submenu cannot offer it. Reading one
    // is separate and needs neither that tool nor a flag, see extract_argv below.
    pub fn from_tools(have_bsdtar: bool, have_7z: bool) -> Formats {
        let mut names = Vec::new();
        if have_bsdtar {
            names.extend(TAR_FORMATS.iter().map(|s| s.to_string()));
        }
        if have_7z {
            names.push(SEVENZIP_FORMAT.to_string());
        }
        Formats { names, have_bsdtar, have_7z,
            #[cfg(test)]
            probe: false,
            #[cfg(test)]
            block: false,
        }
    }

    // A Formats whose compressor is the RLIMIT_CPU probe, so the uncapped-jail pin drives compress() itself.
    #[cfg(test)]
    pub fn test_probe() -> Formats {
        Formats { names: vec!["zip".to_string()], have_bsdtar: true, have_7z: false, probe: true, block: false }
    }

    // A Formats whose compressor blocks until killed, so a mid-run cancel always has a live child.
    #[cfg(test)]
    pub fn test_block() -> Formats {
        Formats { names: vec!["zip".to_string()], have_bsdtar: true, have_7z: false, probe: false, block: true }
    }

    // Exactly the table, which is what the compress submenu draws; an empty one self-hides the entry.
    pub fn names(&self) -> &[String] {
        &self.names
    }

    pub fn offers(&self, format: &str) -> bool {
        self.names.iter().any(|n| n == format)
    }

    // A password is a 7z job whatever the format: bsdtar writes no encryption, and zip's own
    // ZipCrypto is broken, so the With-password row hides where 7z is missing.
    pub fn has_7z(&self) -> bool {
        self.have_7z
    }

    // bsdtar's -a picks the compression from the destination's own extension, so one argv covers
    // every tar flavour and zip; 7z is its own tool and its own shape.
    // corner: bsdtar reads -C positionally, so it has to precede the names it applies to. Putting it
    // after them archives nothing, prints "Cannot stat" per name, and still leaves an empty archive.
    pub fn compress_argv(&self, format: &str, dest: &Path, parent: &Path, names: &[String]) -> Option<Vec<String>> {
        if !self.offers(format) {
            return None;
        }
        // Test seam: with the block set, the compressor stays alive until the cancel stops it.
        #[cfg(test)]
        if self.block {
            return Some(vec!["/usr/bin/sleep".to_string(), "30".to_string()]);
        }
        // Test seam: with the probe set, the compressor is the RLIMIT_CPU probe.
        #[cfg(test)]
        if self.probe {
            return Some(vec!["/usr/bin/python3".to_string(), "-c".to_string(),
                "import resource,sys; open(sys.argv[1],'wb').write(b'probe'); sys.exit(0 if resource.getrlimit(resource.RLIMIT_CPU)[0]==resource.RLIM_INFINITY else 1)".to_string(),
                dest.to_string_lossy().to_string()]);
        }
        let mut a: Vec<String> = Vec::with_capacity(names.len() + 7);
        if format == SEVENZIP_FORMAT {
            a.push(SEVENZIP.to_string());
            a.push("a".to_string());
            a.push("-bd".to_string());
            a.push(dest.to_string_lossy().to_string());
            // 7z stores the basename of an absolute path, so it needs no working-directory flag.
            a.extend(names.iter().map(|n| parent.join(n).to_string_lossy().to_string()));
            return Some(a);
        }
        a.push(BSDTAR.to_string());
        a.push("-a".to_string());
        a.push("-c".to_string());
        a.push("-f".to_string());
        a.push(dest.to_string_lossy().to_string());
        a.push("-C".to_string());
        a.push(parent.to_string_lossy().to_string());
        // Members are relative names from the selection; one that begins with a dash would be read
        // as a bsdtar option (`--use-compress-program` runs an arbitrary program), so option parsing
        // is terminated first, the same way trash.rs does before its own paths.
        a.push("--".to_string());
        a.extend(names.iter().cloned());
        Some(a)
    }

    // The one reader choice, shared by extract_argv and list_argv; None when no tool reads it.
    pub fn reader_for(&self, archive: &Path) -> Option<Reader> {
        let name = archive.to_string_lossy().to_lowercase();
        if name.ends_with(".7z") {
            return self.have_7z.then_some(Reader::SevenZip);
        }
        if ZIP_SUFFIXES.iter().any(|suffix| name.ends_with(*suffix)) {
            if self.have_bsdtar {
                // A rar prefers 7z's reference reader; a zip stays with libarchive where it was.
                return Some(if name.ends_with(".rar") && self.have_7z { Reader::SevenZip } else { Reader::Bsdtar });
            }
            return self.have_7z.then_some(Reader::SevenZip);
        }
        if TAR_SUFFIXES.iter().any(|suffix| name.ends_with(*suffix)) {
            return self.have_bsdtar.then_some(Reader::Bsdtar);
        }
        if SEVEN_SUFFIXES.iter().any(|suffix| name.ends_with(*suffix)) {
            return self.have_7z.then_some(Reader::SevenZip);
        }
        // An unrecognised name keeps the libarchive attempt; the client only asks about the classes above.
        self.have_bsdtar.then_some(Reader::Bsdtar)
    }

    // The zip-class bit the client's Extract row reads; see formats_line in archivereq.rs.
    pub fn zip_readable(&self) -> bool {
        self.have_bsdtar || self.have_7z
    }

    // A disk image the client lists but never extracts; the extract refusal names this.
    pub fn is_list_only(archive: &Path) -> bool {
        let name = archive.to_string_lossy().to_lowercase();
        LIST_ONLY_SUFFIXES.iter().any(|suffix| name.ends_with(*suffix))
    }

    // Extraction is chosen by what the archive is, not by what the caller says it is. A disk
    // image lists only, so it builds no argv here and the client never starts a job for one.
    pub fn extract_argv(&self, archive: &Path, dest: &Path) -> Option<Vec<String>> {
        let name = archive.to_string_lossy().to_lowercase();
        if LIST_ONLY_SUFFIXES.iter().any(|suffix| name.ends_with(*suffix)) {
            return None;
        }
        match self.reader_for(archive)? {
            Reader::SevenZip => Some(vec![
                SEVENZIP.to_string(),
                "x".to_string(),
                "-bd".to_string(),
                "-y".to_string(),
                archive.to_string_lossy().to_string(),
                format!("-o{}", dest.to_string_lossy()),
            ]),
            // bsdtar's secure-extraction default is exercised by the native archive tests.
            Reader::Bsdtar => Some(vec![
                BSDTAR.to_string(),
                "-x".to_string(),
                "-f".to_string(),
                archive.to_string_lossy().to_string(),
                "-C".to_string(),
                dest.to_string_lossy().to_string(),
            ]),
        }
    }

    // The argv that lists an archive without extracting a byte of it.
    pub fn list_argv(&self, archive: &Path) -> Option<(Vec<String>, ListSpec)> {
        match self.reader_for(archive)? {
            Reader::SevenZip => Some((
                vec![SEVENZIP.to_string(), "l".to_string(), "-ba".to_string(),
                     archive.to_string_lossy().to_string()],
                seven_spec(),
            )),
            Reader::Bsdtar => Some((
                vec![BSDTAR.to_string(), "-t".to_string(), "-v".to_string(), "-f".to_string(),
                     archive.to_string_lossy().to_string()],
                tar_spec(),
            )),
        }
    }
}


#[cfg(test)]
#[path = "archive_tests.rs"]
mod tests;
