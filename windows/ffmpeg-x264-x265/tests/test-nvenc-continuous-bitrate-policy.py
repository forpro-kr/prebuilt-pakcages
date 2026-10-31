#!/usr/bin/env python3
"""Run the exported FFmpeg NVENC transaction with an injected NVENC entrypoint.

This portable test compiles the actual patched reconfig_encoder() body, using
the real NVENC API header and minimal FFmpeg owner-state definitions. It tests
the reset/IDR and commit/rollback decisions, not GPU encoding or bitrate output.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-dir', type=Path, required=True,
                        help='The exported, patched FFmpeg source directory')
    parser.add_argument('--nvcodec-include', type=Path, required=True,
                        help='Include directory containing ffnvcodec/nvEncodeAPI.h')
    parser.add_argument('--compiler', default='cc')
    parser.add_argument('--avutil-include', type=Path,
                        help='Optional real libavutil include directory for defaults/read-only API checks')
    parser.add_argument('--avutil-library', type=Path,
                        help='Optional real libavutil library/import library; requires --avutil-include')
    args = parser.parse_args()
    assert bool(args.avutil_include) == bool(args.avutil_library)
    source = (args.source_dir / 'libavcodec/nvenc.c').read_text()
    start = source.index('static int reconfig_encoder(')
    end = source.index('#ifdef NVENC_HAVE_HEVC_AND_AV1_MASTERING_METADATA\nstatic int nvenc_set_mastering', start)
    production = source[start:end]
    init_start = source.index('av_cold int ff_nvenc_encode_init(')
    init_end = source.index('\nstatic NvencSurface *get_free_frame', init_start)
    init_production = source[init_start:init_end]
    close_start = source.index('av_cold int ff_nvenc_encode_close(')
    close_prefix_end = source.index('    /* the encoder has to be flushed', close_start)
    close_prefix = source[close_start:close_prefix_end] + '    return 0;\n}\n'
    for codec in ('nvenc_h264.c', 'nvenc_hevc.c'):
        options = (args.source_dir / 'libavcodec' / codec).read_text()
        version = next(line for line in options.splitlines() if '"repc_continuous_bitrate_version"' in line)
        assert 'AV_OPT_TYPE_INT' in version and '{ .i64 = 2 }, 2, 2' in version
        assert 'AV_OPT_FLAG_READONLY' in version
    fixture = r'''
#include <assert.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <ffnvcodec/nvEncodeAPI.h>
#define AVERROR(e) (-(e))
#define AVERROR_EXTERNAL (-10000)
#define AV_LOG_VERBOSE 1
#define AV_LOG_ERROR 2
#define AV_PIX_FMT_CUDA 1
#define AV_PIX_FMT_D3D11 2
#define NVENC_RGB_MODE_DISABLED 1
#define IS_RGB(format) 0
#define AV_CODEC_FLAG_GLOBAL_HEADER 1
#define av_cold
typedef struct AVFrame { int unused; } AVFrame;
typedef struct AVBufferRef { void *data; } AVBufferRef;
typedef struct AVHWFramesContext { int format,sw_format; } AVHWFramesContext;
typedef struct AVCodecContext {
    void *priv_data;
    int64_t bit_rate, rc_max_rate;
    int rc_buffer_size;
    int pix_fmt,flags;
    AVBufferRef *hw_frames_ctx;
} AVCodecContext;
typedef struct NvencDynLoadFunctions { NV_ENCODE_API_FUNCTION_LIST nvenc_funcs; } NvencDynLoadFunctions;
typedef struct NvencContext {
    NvencDynLoadFunctions nvenc_dload_funcs;
    void *nvencoder;
    NV_ENC_CONFIG encode_config;
    NV_ENC_INITIALIZE_PARAMS init_encode_params;
    int repc_continuous_bitrate, support_dyn_bitrate, rc, repc_continuous_bitrate_version;
    int data_pix_fmt,rgb_mode;
    AVFrame *frame;
    int64_t repc_applied_bitrate;
} NvencContext;
static int wanted_dar=16;
static void compute_dar(AVCodecContext *av, int *w, int *h) { *w=wanted_dar; *h=9; }
static void av_log(void *owner, int level, const char *format, ...) { }
static int nvenc_print_error(void *owner, NVENCSTATUS status, const char *message) { return AVERROR_EXTERNAL; }
/*PRODUCTION*/
static int init_failure;
static AVFrame allocation;
static AVFrame *av_frame_alloc(void) { return init_failure==6 ? NULL : &allocation; }
static int nvenc_load_libraries(AVCodecContext *av) { return init_failure==1 ? AVERROR(EINVAL) : 0; }
static int nvenc_setup_device(AVCodecContext *av) { return init_failure==2 ? AVERROR(EINVAL) : 0; }
static int nvenc_setup_encoder(AVCodecContext *av) { return init_failure==3 ? AVERROR(EINVAL) : 0; }
static int nvenc_setup_surfaces(AVCodecContext *av) { return init_failure==4 ? AVERROR(EINVAL) : 0; }
static int nvenc_setup_extradata(AVCodecContext *av) { return init_failure==5 ? AVERROR(EINVAL) : 0; }
/*INIT_PRODUCTION*/
/*CLOSE_PREFIX*/
typedef struct Driver {
    int calls, resets, idrs, fail;
    unsigned last_rate, last_peak, last_vbv;
} Driver;
static NVENCSTATUS NVENCAPI reconfigure(void *encoder, NV_ENC_RECONFIGURE_PARAMS *params) {
    Driver *driver=encoder;
    ++driver->calls; driver->resets+=params->resetEncoder!=0; driver->idrs+=params->forceIDR!=0;
    if (params->reInitEncodeParams.encodeConfig) {
        NV_ENC_RC_PARAMS *rc=&params->reInitEncodeParams.encodeConfig->rcParams;
        driver->last_rate=rc->averageBitRate;driver->last_peak=rc->maxBitRate;driver->last_vbv=rc->vbvBufferSize;
    }
    return driver->fail ? NV_ENC_ERR_GENERIC : NV_ENC_SUCCESS;
}
static void init(NvencContext *state, AVCodecContext *av, Driver *driver, unsigned fps, int hevc) {
    memset(state,0,sizeof(*state));memset(av,0,sizeof(*av));memset(driver,0,sizeof(*driver));
    av->priv_data=state;av->bit_rate=av->rc_max_rate=10000000;av->rc_buffer_size=10000000/fps;
    state->nvencoder=driver;state->repc_continuous_bitrate=state->support_dyn_bitrate=1;
    state->rc=NV_ENC_PARAMS_RC_CBR;state->repc_applied_bitrate=10000000;
    state->encode_config.rcParams.averageBitRate=state->encode_config.rcParams.maxBitRate=10000000;
    state->encode_config.rcParams.vbvBufferSize=av->rc_buffer_size;
    state->init_encode_params.darWidth=16;state->init_encode_params.darHeight=9;
    state->init_encode_params.encodeConfig=&state->encode_config;
    state->init_encode_params.encodeGUID=hevc ? NV_ENC_CODEC_HEVC_GUID : NV_ENC_CODEC_H264_GUID;
    state->nvenc_dload_funcs.nvenc_funcs.nvEncReconfigureEncoder=reconfigure;wanted_dar=16;
}
static void set_rate(AVCodecContext *av, unsigned rate, unsigned fps) {
    av->bit_rate=av->rc_max_rate=rate;av->rc_buffer_size=rate/fps;
}
/*REAL_AVUTIL_DECLARATIONS*/
static void contract_version_lifecycle(void) {
    NvencContext state;AVCodecContext av;Driver driver;
    init(&state,&av,&driver,60,1);av.flags=AV_CODEC_FLAG_GLOBAL_HEADER;
    // The FFmpeg private context is zeroed; READONLY options are skipped by
    // av_opt_set_defaults2(), so a default value of 2 does not initialize it.
    assert(state.repc_continuous_bitrate_version==0);
    /*REAL_AVUTIL_DEFAULT_CHECK*/
    assert(ff_nvenc_encode_init(&av)==0 && state.repc_continuous_bitrate_version==2);
    /*REAL_AVUTIL_OPEN_CHECK*/
    for(init_failure=1;init_failure<=6;++init_failure) {
        state.repc_continuous_bitrate_version=2; // Reused private storage.
        assert(ff_nvenc_encode_init(&av)<0 && state.repc_continuous_bitrate_version==0);
    }
    init_failure=0;assert(ff_nvenc_encode_init(&av)==0);
    assert(ff_nvenc_encode_close(&av)==0 && state.repc_continuous_bitrate_version==0);
    av.pix_fmt=AV_PIX_FMT_CUDA; // Early input-validation failure also clears it.
    state.repc_continuous_bitrate_version=2;
    assert(ff_nvenc_encode_init(&av)==AVERROR(EINVAL) && state.repc_continuous_bitrate_version==0);
    puts("nvenc_contract_version lifecycle=0-before-open/2-after-init/0-on-failure-and-close");
}
static void ramp_and_failures(unsigned fps, int hevc) {
    NvencContext state, independent;AVCodecContext av, other;Driver driver, isolated;
    init(&state,&av,&driver,fps,hevc);init(&independent,&other,&isolated,fps,hevc);
    for(unsigned rate=11000000;rate<=50000000;rate+=1000000) {
        set_rate(&av,rate,fps);assert(reconfig_encoder(&av,NULL)==0);
        assert(driver.resets==0 && driver.idrs==0);
        assert(state.repc_applied_bitrate==rate && state.encode_config.rcParams.vbvBufferSize==rate/fps);
    }
    set_rate(&av,5000000,fps);assert(reconfig_encoder(&av,NULL)==0);
    assert(driver.resets==0 && driver.idrs==0 && driver.calls==41);
    const int calls=driver.calls;
    assert(reconfig_encoder(&av,NULL)==0 && driver.calls==calls);
    assert(isolated.calls==0 && independent.repc_applied_bitrate==10000000);
    // A rejected upshift does not commit a requested rate, inject a reset,
    // or secretly recreate the session. Restoring the last rate is reusable.
    driver.fail=1;set_rate(&av,25000000,fps);
    assert(reconfig_encoder(&av,NULL)==AVERROR_EXTERNAL);
    assert(state.repc_applied_bitrate==5000000 && state.encode_config.rcParams.averageBitRate==5000000);
    assert(driver.resets==0 && driver.idrs==0);
    driver.fail=0;set_rate(&av,5000000,fps);
    assert(reconfig_encoder(&av,NULL)==0 && driver.calls==calls+1);
    // VBR peak-only changes and its zero sentinel retain rate-only semantics.
    state.rc=NV_ENC_PARAMS_RC_VBR;av.rc_max_rate=8000000;
    assert(reconfig_encoder(&av,NULL)==0 && state.encode_config.rcParams.maxBitRate==8000000);
    av.rc_max_rate=0;set_rate(&av,6000000,fps);av.rc_max_rate=0;
    assert(reconfig_encoder(&av,NULL)==0 && state.encode_config.rcParams.maxBitRate==8000000);
    assert(driver.resets==0 && driver.idrs==0);
    // A separate format/aspect-ratio change still has the original reset/IDR
    // behavior when combined with a rate change.
    wanted_dar=32;set_rate(&av,7000000,fps);
    assert(reconfig_encoder(&av,NULL)==0 && driver.resets==1 && driver.idrs==1);
    assert(state.init_encode_params.darWidth==32);
    printf("nvenc_continuous_rate codec=%s fps=%u ramp_resets=0 ramp_idrs=0 failure_preserved=1 independent=1 dar_reset=1\n",hevc?"hevc":"h264",fps);
    // Upstream behavior is unchanged unless the app explicitly opts in.
    init(&state,&av,&driver,fps,hevc);state.repc_continuous_bitrate=0;
    set_rate(&av,20000000,fps);
    assert(reconfig_encoder(&av,NULL)==0 && driver.resets==1 && driver.idrs==1);
    init(&state,&av,&driver,fps,hevc);state.support_dyn_bitrate=0;
    set_rate(&av,20000000,fps);
    assert(reconfig_encoder(&av,NULL)==AVERROR(ENOSYS) && driver.calls==0);
    init(&state,&av,&driver,fps,hevc);state.rc=NV_ENC_PARAMS_RC_CONSTQP;
    set_rate(&av,20000000,fps);
    assert(reconfig_encoder(&av,NULL)==AVERROR(ENOSYS) && driver.calls==0);
}
int main(void) { contract_version_lifecycle();for(unsigned fps=60;fps<=120;fps+=60) for(int hevc=0;hevc<=1;++hevc) ramp_and_failures(fps,hevc); }
'''.replace('/*PRODUCTION*/', production).replace('/*INIT_PRODUCTION*/', init_production).replace('/*CLOSE_PREFIX*/', close_prefix)
    real_api_source = ''
    if args.avutil_library:
        version_line = next(line for line in options.splitlines() if '"repc_continuous_bitrate_version"' in line)
        real_api_source = r'''
#include <assert.h>
#include <stddef.h>
#include <libavutil/opt.h>
#include <libavutil/version.h>
typedef struct ProbeContext { const AVClass *avclass;int repc_continuous_bitrate_version; } ProbeContext;
#define OFFSET(member) offsetof(ProbeContext,member)
#define VE (AV_OPT_FLAG_VIDEO_PARAM | AV_OPT_FLAG_ENCODING_PARAM)
static const AVOption options[] = {
/*VERSION_OPTION*/
    {NULL}
};
static const AVClass probe_class = {.class_name="nvenc-contract-probe",.item_name=av_default_item_name,.option=options,.version=LIBAVUTIL_VERSION_INT};
void real_version_check(int *version, int expected, int apply_defaults) {
    ProbeContext context={&probe_class,*version};int64_t observed=-1;
    if(apply_defaults)av_opt_set_defaults2(&context,0,0);
    assert(av_opt_get_int(&context,"repc_continuous_bitrate_version",0,&observed)==0 && observed==expected);
    assert(av_opt_set_int(&context,"repc_continuous_bitrate_version",1,0)<0);
    assert(context.repc_continuous_bitrate_version==expected);
    *version=context.repc_continuous_bitrate_version;
}
'''.replace('/*VERSION_OPTION*/', version_line)
        fixture = fixture.replace('/*REAL_AVUTIL_DECLARATIONS*/', 'void real_version_check(int *,int,int);')
        fixture = fixture.replace('/*REAL_AVUTIL_DEFAULT_CHECK*/', 'real_version_check(&state.repc_continuous_bitrate_version,0,1);')
        fixture = fixture.replace('/*REAL_AVUTIL_OPEN_CHECK*/', 'real_version_check(&state.repc_continuous_bitrate_version,2,0);')
    with tempfile.TemporaryDirectory(prefix='airdesk-nvenc-rate-policy-') as temp:
        temp = Path(temp)
        harness, executable = temp/'rate.c', temp/'rate-policy'
        harness.write_text(fixture)
        command = [args.compiler, '-std=c11', '-O0', '-UNDEBUG',
                   '-I'+str(args.nvcodec_include.resolve()), str(harness)]
        if real_api_source:
            api = temp/'real-avutil.c';api.write_text(real_api_source)
            command += ['-I'+str(args.avutil_include.resolve()), str(api), str(args.avutil_library.resolve())]
        subprocess.run(command+['-o',str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=15)


if __name__ == '__main__':
    main()
