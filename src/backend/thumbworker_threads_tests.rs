use super::*;

// One libav thread per video, so the count reads 1 once the decoder loads.
#[test]
fn loading_the_decoder_forces_one_libav_thread() {
    let Some(_) = Decoder::load(SONAME) else { return };
    unsafe {
        let library = dlopen(SONAME.as_ptr(), RTLD_NOW);
        assert!(!library.is_null(), "the decoder library did not stay open");
        let found = dlsym(library, c"av_cpu_count".as_ptr());
        assert!(!found.is_null(), "libavutil answers no av_cpu_count");
        let count: unsafe extern "C" fn() -> c_int = std::mem::transmute(found);
        assert_eq!(count(), 1, "the decoder did not force one libav thread");
    }
}
