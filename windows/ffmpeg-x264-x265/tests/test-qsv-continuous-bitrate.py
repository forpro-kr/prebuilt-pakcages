#!/usr/bin/env python3
"""Run patched QSV transaction functions with real headers and injected MFX.

No Intel device is opened. SDK acceptance/rollback, deadlines and FIFO ownership
are tested separately from physical encoding throughput and picture quality.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


parser = argparse.ArgumentParser()
parser.add_argument('--build-dir', type=Path, required=True)
parser.add_argument('--compiler', default='gcc')
parser.add_argument('--runtime-dir', type=Path)
args = parser.parse_args()
build = args.build_dir.resolve()
source = build / 'ffmpeg/source'
code = (source / 'libavcodec/qsvenc.c').read_text()
contract = code[code.index('/* RePC QSV continuous bitrate contract:'):code.index('static int update_parameters(')]
assert 'repc_qsv_update_bitrate(avctx, q)' in code
assert 'if (!q->repc_continuous_bitrate)\n        needReset |= update_bitrate' in code
assert 'return repc_qsv_init_bitrate(avctx, q);' in code
assert 'q->param.ExtParam = repc_saved_ext;' in code  # No expired retrieval-stack pointers.
assert 'FIFO still owns unsynchronized output memory' in code
assert 'av_gettime_relative() >= repc_deadline' in code

header = r'''
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include "libavutil/time.h"
#include "libavutil/mathematics.h"
#include "libavcodec/qsvenc.h"
typedef struct QSVPacket {AVPacket pkt; mfxSyncPoint *sync; mfxBitstream *bs;} QSVPacket;
struct AVFifo {QSVPacket packets[64]; mfxSyncPoint syncs[64]; size_t count;};
typedef struct Driver {
    mfxVideoParam actual;
    mfxExtCodingOption3 coding;
    int queries, gets, resets, support_fail, query_change, reset_fail, lie_reset;
    int rollback_fail, mutate_reset, mutate_query, get_fail, partial_reset;
    int delayed, sync_busy, sync_calls, drain_calls;
} Driver;
static int64_t now_us;
int64_t av_gettime_relative(void) {return now_us+=100;}
int64_t av_rescale_rnd(int64_t a,int64_t b,int64_t c,enum AVRounding r) {return (a*b+c-1)/c;}
void av_log(void *p,int l,const char *f,...) {}
void *av_calloc(size_t n,size_t s) {return calloc(n,s);}
void *av_mallocz(size_t n) {return calloc(1,n);}
void *av_memdup(const void *p,size_t n) {void *v=malloc(n);if(v)memcpy(v,p,n);return v;}
void av_freep(void *p) {free(*(void**)p);*(void**)p=NULL;}
size_t av_fifo_can_read(const AVFifo *f) {return f->count;}
int av_fifo_peek(const AVFifo *f,void *p,size_t n,size_t off) {
    if(n!=1 || off>=f->count)return AVERROR(EINVAL);
    *(QSVPacket*)p=f->packets[off];return 0;
}
int ff_qsv_print_error(void *a,mfxStatus s,const char *m) {return AVERROR_EXTERNAL;}
static void copy_result(mfxVideoParam *dst,const mfxVideoParam *src,Driver *d) {
    mfxExtBuffer **ext=dst->ExtParam; mfxU16 count=dst->NumExtParam;
    *dst=*src;dst->ExtParam=ext;dst->NumExtParam=count;
    for(int i=0;i<count;i++) {
        if(ext[i]->BufferId==MFX_EXTBUFF_CODING_OPTION3)
            *(mfxExtCodingOption3*)ext[i]=d->coding;
    }
}
mfxStatus MFX_CDECL MFXVideoENCODE_GetVideoParam(mfxSession s,mfxVideoParam *p) {
    Driver*d=(Driver*)s;++d->gets;
    if(d->get_fail && d->gets==d->get_fail)return MFX_ERR_DEVICE_FAILED;
    copy_result(p,&d->actual,d);return MFX_ERR_NONE;
}
mfxStatus MFX_CDECL MFXVideoENCODE_Query(mfxSession s,mfxVideoParam *in,mfxVideoParam*out) {
    Driver*d=(Driver*)s;++d->queries;
    if(!in)return d->support_fail?MFX_ERR_UNSUPPORTED:MFX_ERR_NONE;
    copy_result(out,in,d);
    if(d->query_change)out->mfx.FrameInfo.CropW++;
    if(d->mutate_query)in->mfx.FrameInfo.CropW++;
    return MFX_ERR_NONE;
}
mfxStatus MFX_CDECL MFXVideoENCODE_Reset(mfxSession s,mfxVideoParam *p) {
    Driver*d=(Driver*)s;++d->resets;
    int continuation=0;
    for(int i=0;i<p->NumExtParam;i++)if(p->ExtParam[i]->BufferId==MFX_EXTBUFF_ENCODER_RESET_OPTION) {
        mfxExtEncoderResetOption*r=(mfxExtEncoderResetOption*)p->ExtParam[i];
        continuation=r->StartNewSequence==MFX_CODINGOPTION_OFF;
        if(d->mutate_reset && d->resets==1)r->StartNewSequence=MFX_CODINGOPTION_ON;
    }
    assert(continuation); // No IDR/new sequence on decrease or recovery.
    if((d->reset_fail&&d->resets==1)||(d->rollback_fail&&d->resets>1))return MFX_ERR_DEVICE_FAILED;
    d->actual=*p;d->actual.ExtParam=NULL;d->actual.NumExtParam=0;
    if(d->lie_reset && d->resets==1)d->actual.mfx.TargetKbps++;
    return d->partial_reset&&d->resets==1?MFX_WRN_PARTIAL_ACCELERATION:MFX_ERR_NONE;
}
mfxStatus MFX_CDECL MFXVideoCORE_SyncOperation(mfxSession s,mfxSyncPoint p,mfxU32 wait) {
    Driver*d=(Driver*)s;++d->sync_calls;assert(wait==1);now_us+=1000;
    return d->sync_busy?MFX_WRN_IN_EXECUTION:MFX_ERR_NONE;
}
static int encode_frame(AVCodecContext *av,QSVEncContext*q,const AVFrame*f) {
    Driver*d=(Driver*)q->session;++d->drain_calls;assert(!f);
    if(!d->delayed)return AVERROR(EAGAIN);
    --d->delayed;
    AVFifo* fifo=q->async_fifo;size_t i=fifo->count++;
    fifo->syncs[i]=(mfxSyncPoint)(uintptr_t)(i+1);
    fifo->packets[i].sync=&fifo->syncs[i];fifo->packets[i].pkt.pts=i+100;
    return 0;
}
'''
tests = r'''
static void init(QSVEncContext*q,AVCodecContext*av,Driver*d,AVFifo*f,int mode,int fps) {
    *q=(QSVEncContext){0};*av=(AVCodecContext){0};*d=(Driver){0};*f=(AVFifo){0};now_us=0;
    q->session=(mfxSession)d;q->async_fifo=f;q->repc_continuous_bitrate=1;q->repc_rate_control=mode;
    q->param.AsyncDepth=1;q->param.IOPattern=MFX_IOPATTERN_IN_VIDEO_MEMORY;
    q->param.mfx.CodecId=MFX_CODEC_HEVC;q->param.mfx.CodecProfile=MFX_PROFILE_HEVC_MAIN;
    q->param.mfx.RateControlMethod=mode;q->param.mfx.BRCParamMultiplier=1;
    q->param.mfx.TargetKbps=10000;q->param.mfx.MaxKbps=mode==MFX_RATECONTROL_VBR?12000:10000;
    q->param.mfx.FrameInfo.CropW=1920;q->param.mfx.FrameInfo.CropH=1080;
    q->param.mfx.GopRefDist=1;q->param.mfx.BufferSizeInKB=512;
    d->coding.Header=(mfxExtBuffer){MFX_EXTBUFF_CODING_OPTION3,sizeof(d->coding)};
    d->coding.LowDelayBRC=MFX_CODINGOPTION_ON;
    q->extco3=d->coding;q->extparam_internal[0]=(mfxExtBuffer*)&q->extco3;
    q->param.ExtParam=q->extparam_internal;q->param.NumExtParam=1;d->actual=q->param;
    q->old_bit_rate=av->bit_rate=10000000;
    q->old_rc_max_rate=av->rc_max_rate=mode==MFX_RATECONTROL_VBR?12000000:10000000;
    av->framerate=(AVRational){fps,1};av->priv_data=q;
    assert(repc_qsv_init_bitrate(av,q)==0 && q->repc_applied_bitrate==10000000);
}
static void set_rate(AVCodecContext*av,int mode,int kbps) {
    av->bit_rate=(int64_t)kbps*1000;
    av->rc_max_rate=mode==MFX_RATECONTROL_VBR?(av->bit_rate*6+4)/5:av->bit_rate;
}
static void check_mode(int mode,int fps) {
    QSVEncContext q;AVCodecContext av;Driver d;AVFifo fifo;
    init(&q,&av,&d,&fifo,mode,fps);
    for(int i=0;i<3;i++) {
        int rate=(int[]){2000,14000,10000}[i];set_rate(&av,mode,rate);
        d.delayed=2;
        assert(repc_qsv_update_bitrate(&av,&q)==0);
        assert(q.repc_applied_bitrate==av.bit_rate && q.repc_applied_peak_bitrate==av.rc_max_rate);
        assert(q.repc_applied_rc==mode && q.repc_bitrate_error==0);
        assert(fifo.count==(size_t)(2*(i+1)) && fifo.packets[0].pkt.pts==100);
        for(size_t n=0;n<fifo.count;n++)assert(*fifo.packets[n].sync==NULL);
        int resets=d.resets;assert(repc_qsv_update_bitrate(&av,&q)==0 && d.resets==resets);
    }
    for(int failure=0;failure<7;failure++) {
        init(&q,&av,&d,&fifo,mode,fps);set_rate(&av,mode,2000);
        d.support_fail=failure==0;d.query_change=failure==1;d.reset_fail=failure==2;
        d.lie_reset=failure==3||failure==6;d.mutate_reset=failure==4;
        d.partial_reset=failure==5;d.rollback_fail=failure==6;
        assert(repc_qsv_update_bitrate(&av,&q)<0);
        assert(av.bit_rate==10000000 && q.old_bit_rate==10000000);
        assert(q.repc_applied_bitrate==(failure==6?-1:10000000));
        assert(q.repc_bitrate_error==(failure==6?-1:1));
        assert(q.extco3.LowDelayBRC==MFX_CODINGOPTION_ON);
        if(failure<2)assert(d.resets==0 && d.drain_calls==0);
        if(failure!=6) {
            d.support_fail=d.query_change=d.reset_fail=d.lie_reset=d.mutate_reset=d.partial_reset=0;
            set_rate(&av,mode,4000);assert(repc_qsv_update_bitrate(&av,&q)==0);
        }
    }
    init(&q,&av,&d,&fifo,mode,fps);d.mutate_query=1;set_rate(&av,mode,4000);
    assert(repc_qsv_update_bitrate(&av,&q)==0 && d.actual.mfx.FrameInfo.CropW==1920);
    init(&q,&av,&d,&fifo,mode,fps);d.get_fail=2;set_rate(&av,mode,4000);
    assert(repc_qsv_update_bitrate(&av,&q)<0 && d.resets==0 && q.repc_applied_bitrate==10000000);
    init(&q,&av,&d,&fifo,mode,fps);d.delayed=1;d.sync_busy=1;set_rate(&av,mode,4000);
    assert(repc_qsv_update_bitrate(&av,&q)<0 && q.repc_applied_bitrate==-1);
    assert(fifo.count==1 && *fifo.packets[0].sync!=NULL && d.resets==0);
    assert(now_us<=repc_qsv_timeout_us(&av)+3000); // Requested FPS controls the wait.
    init(&q,&av,&d,&fifo,mode,fps);set_rate(&av,mode,1000000);
    assert(repc_qsv_update_bitrate(&av,&q)==0);
    assert(q.repc_applied_bitrate>=1000000000LL && q.repc_applied_bitrate-1000000000LL<q.repc_bitrate_quantum);
}
int main(void) {
    check_mode(MFX_RATECONTROL_CBR,60);check_mode(MFX_RATECONTROL_CBR,120);
    check_mode(MFX_RATECONTROL_VBR,60);check_mode(MFX_RATECONTROL_VBR,120);
    QSVEncContext a,b;AVCodecContext av,bv;Driver x,y;AVFifo af,bf;
    init(&a,&av,&x,&af,MFX_RATECONTROL_CBR,60);init(&b,&bv,&y,&bf,MFX_RATECONTROL_VBR,120);
    set_rate(&av,MFX_RATECONTROL_CBR,2000);assert(repc_qsv_update_bitrate(&av,&a)==0);
    assert(b.repc_applied_bitrate==10000000 && y.resets==0 && y.actual.mfx.RateControlMethod==MFX_RATECONTROL_VBR);
    puts("qsv_continuous_bitrate_transactions=ok (CBR/VBR 60/120, FIFO, query/reset/readback/rollback, timeout, independent sessions)");
}
'''
with tempfile.TemporaryDirectory(prefix='repc-qsv-contract-') as temporary:
    temp = Path(temporary)
    (temp / 'config.h').write_text('#define CONFIG_D3D11VA 0\n#define CONFIG_VAAPI 0\n#define CONFIG_LIBVPL 1\n')
    harness, exe = temp / 'test.c', temp / 'test.exe'
    harness.write_text(header + contract + tests)
    subprocess.run([args.compiler, '-std=c11', '-O0', str(harness), '-I' + str(temp),
                    '-I' + str(source), '-I' + str(build / 'ffmpeg'),
                    '-I' + str(source / 'libavcodec'), '-I' + str(build / 'prefix/include'),
                    '-I' + str(build / 'prefix/include/vpl'),
                    '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)

if args.runtime_dir:
    runtime = args.runtime_dir.resolve()
    manifest = json.loads((runtime / 'repc-ffmpeg-codec-build.json').read_text())
    patch = Path(__file__).resolve().parent.parent / 'patches/0004-qsv-continuous-bitrate.patch'
    assert manifest['qsvContinuousBitratePatchSha256'] == hashlib.sha256(patch.read_bytes()).hexdigest()
    with os.add_dll_directory(str(runtime)):
        util = ctypes.CDLL(str(runtime / 'repc-codec-avutil-60.dll'))
        codec = ctypes.CDLL(str(runtime / 'repc-codec-avcodec-62.dll'))
        codec.avcodec_find_encoder_by_name.argtypes = [ctypes.c_char_p]
        codec.avcodec_find_encoder_by_name.restype = ctypes.c_void_p
        codec.avcodec_alloc_context3.argtypes = [ctypes.c_void_p]
        codec.avcodec_alloc_context3.restype = ctypes.c_void_p
        codec.avcodec_free_context.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
        util.av_opt_set_int.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int64, ctypes.c_int]
        util.av_opt_get_int.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(ctypes.c_int64)]
        for name in (b'h264_qsv', b'hevc_qsv', b'av1_qsv'):
            enc = codec.avcodec_find_encoder_by_name(name)
            assert enc, name
            context = ctypes.c_void_p(codec.avcodec_alloc_context3(enc))
            assert context.value, name
            try:
                for mode in (1, 2):
                    assert util.av_opt_set_int(context, b'repc_rate_control', mode, 1) == 0
                assert util.av_opt_set_int(context, b'repc_continuous_bitrate', 1, 1) == 0
                for key in (b'repc_applied_bitrate', b'repc_applied_peak_bitrate', b'repc_applied_rc', b'repc_bitrate_error'):
                    value = ctypes.c_int64()
                    assert util.av_opt_get_int(context, key, 1, ctypes.byref(value)) == 0 and value.value == 0
                    assert util.av_opt_set_int(context, key, 999, 1) < 0
            finally:
                codec.avcodec_free_context(ctypes.byref(context))
    print('qsv_continuous_bitrate_runtime_options=ok (H264/HEVC/AV1; no Intel device opened)')
