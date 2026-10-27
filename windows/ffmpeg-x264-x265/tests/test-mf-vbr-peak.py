"""Apply the ordered MF patches and execute their actual VBR validation helper."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

package = Path(__file__).resolve().parents[1]
repository = package.parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--compiler", default="c++")
parser.add_argument("--ffmpeg-source", type=Path,
                    default=repository / "build/sources/ffmpeg")
parser.add_argument("--patch", default=shutil.which("patch") or "C:/msys64/usr/bin/patch.exe")
args = parser.parse_args()


def definition(source, signature):
    start = source.index(signature)
    end, depth = source.index("{", start) + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


with tempfile.TemporaryDirectory(prefix="repc-mf-vbr-peak-") as temporary:
    directory = Path(temporary)
    target = directory / "libavcodec/mfenc.c"
    target.parent.mkdir()
    shutil.copyfile(args.ffmpeg_source / "libavcodec/mfenc.c", target)
    shutil.copyfile(args.ffmpeg_source / "configure", directory / "configure")
    for patch in ("0001-mf-low-delay.patch", "0002-mf-upstream-fixes.patch", "0005-mf-vbr-peak.patch"):
        subprocess.run([args.patch, "--batch", "--forward", "-d", str(directory), "-p1",
                        "-i", str(package / "patches" / patch)], check=True, capture_output=True)
    source = target.read_text(encoding="utf-8")
    assert source.count("mf_repc_apply_rate_control(avctx)") == 2
    assert '"repc_vbr_peak_version"' in source
    fixture = r'''
#include <array>
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <iostream>
#define AVERROR(e) (-(e))
#define AV_LOG_ERROR 1
#define FAILED(hr) ((hr)<0)
#define SUCCEEDED(hr) ((hr)>=0)
using HRESULT=int;using GUID=int;
constexpr int VT_UI4=19;
constexpr int ff_eAVEncCommonRateControlMode_PeakConstrainedVBR=1;
constexpr int ff_eAVEncCommonRateControlMode_CBR=0;
const GUID ff_CODECAPI_AVEncCommonRateControlMode=0,
    ff_CODECAPI_AVEncCommonMeanBitRate=1,ff_CODECAPI_AVEncCommonMaxBitRate=2;
struct VARIANT {int vt=0;std::uint32_t ulVal=0;};
struct Driver {
    std::array<std::uint32_t,3> values{};
    int setFail=-1,readFail=-1,mismatch=-1,writes=0,reads=0;
};
struct MFContext {Driver* codec_api=nullptr;int opt_enc_rc=0,repc_require_cbr=0;};
struct AVCodecContext {MFContext* priv_data;std::int64_t bit_rate=10000000,rc_max_rate=12000000;};
static VARIANT* requested(std::uint32_t value){static VARIANT v;v={VT_UI4,value};return &v;}
#define FF_VAL_VT_UI4(v) requested(v)
static HRESULT ICodecAPI_SetValue(Driver* d,const GUID* key,VARIANT* v) {
    ++d->writes;if(d->setFail==*key)return -1;d->values[*key]=v->ulVal;return 0;
}
static HRESULT ICodecAPI_GetValue(Driver* d,const GUID* key,VARIANT* v) {
    ++d->reads;if(d->readFail==*key)return -1;
    v->vt=VT_UI4;v->ulVal=d->mismatch==*key?123:d->values[*key];return 0;
}
static void VariantClear(VARIANT* v){*v={};}
static const char* ff_hr_str(HRESULT){return "injected error";}
static void av_log(AVCodecContext*,int,const char*,...){ }
/*HELPER*/
int main() {
    Driver driver;MFContext mf{&driver};AVCodecContext context{&mf};
    assert(mf_repc_apply_vbr_peak(&context)==0 && driver.writes==0 && driver.reads==0);
    mf.opt_enc_rc=ff_eAVEncCommonRateControlMode_PeakConstrainedVBR;
    for(unsigned fps:{60u,120u}) {
        (void)fps;
        for(std::int64_t target:{10000000,4000000,2000000,20000000}) {
            context.bit_rate=target;context.rc_max_rate=target*6/5;
            driver.values.fill(0); // Device/scenario negotiation reset properties.
            assert(mf_repc_apply_vbr_peak(&context)==0);
            assert(driver.values[0]==1 && driver.values[1]==target && driver.values[2]==target*6/5);
        }
    }
    for(int property=0;property<3;++property) {
        driver.setFail=property;assert(mf_repc_apply_vbr_peak(&context)<0);driver.setFail=-1;
        driver.readFail=property;assert(mf_repc_apply_vbr_peak(&context)<0);driver.readFail=-1;
        driver.mismatch=property;assert(mf_repc_apply_vbr_peak(&context)<0);driver.mismatch=-1;
    }
    context.bit_rate=0;assert(mf_repc_apply_vbr_peak(&context)<0);
    context.bit_rate=10000000;context.rc_max_rate=9999999;assert(mf_repc_apply_vbr_peak(&context)<0);
    context.rc_max_rate=std::int64_t(UINT32_MAX)+1;assert(mf_repc_apply_vbr_peak(&context)<0);
    context.rc_max_rate=12000000;mf.codec_api=nullptr;assert(mf_repc_apply_vbr_peak(&context)<0);
    mf.codec_api=&driver;mf.repc_require_cbr=1;mf.opt_enc_rc=ff_eAVEncCommonRateControlMode_CBR;
    context.bit_rate=context.rc_max_rate=0;
    auto writes=driver.writes,reads=driver.reads;
    assert(mf_repc_apply_vbr_peak(&context)==0 && driver.values[0]==0 &&
        driver.writes==writes+1 && driver.reads==reads+1);
    driver.setFail=0;assert(mf_repc_apply_vbr_peak(&context)<0);driver.setFail=-1;
    driver.mismatch=0;assert(mf_repc_apply_vbr_peak(&context)<0);driver.mismatch=-1;
    driver.readFail=0;assert(mf_repc_apply_vbr_peak(&context)<0);driver.readFail=-1;
    mf.opt_enc_rc=1;assert(mf_repc_apply_vbr_peak(&context)<0);
    std::cout<<"MF pinned patch chain: CBR untouched, VBR mode/mean/peak readback, scenario reset, rejects/limits: PASS\n";
}
'''.replace("/*HELPER*/", definition(source, "static int mf_repc_apply_rate_control(")) \
       .replace("mf_repc_apply_vbr_peak", "mf_repc_apply_rate_control")
    cpp, executable = directory / "test.cpp", directory / "test.exe"
    cpp.write_text(fixture, encoding="utf-8")
    subprocess.run([args.compiler, "-std=c++17", "-UNDEBUG", str(cpp), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
