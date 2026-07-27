# ForPro prebuilt packages

ForPro 제품에서 선택 설치하는 제3자 런타임의 빌드·라이선스·배포 저장소다.

RePC의 GPL FFmpeg/x264/x265 코덱 팩은 이 저장소가 소유한다. RePC 본체
저장소에는 코덱 팩을 빌드하거나 NSIS 설치 파일을 만드는 코드가 들어가지 않고,
이 저장소가 만든 검증된 산출물만 release 입력으로 사용한다.

## 패키지

- [`windows/ffmpeg-x264-x265`](windows/ffmpeg-x264-x265/README.md):
  RePC Windows x64/ARM64용 GPL FFmpeg + libx264 + libx265 런타임과 NSIS 설치 파일

각 package의 `BUILD_STATUS.md`는 구현 완료와 실제 binary/runtime acceptance를
구분해서 기록한다.

바이너리는 Git에 커밋하지 않는다. 빌드 manifest, 대응하는 전체 소스 번들,
라이선스 원문, SHA-256 manifest와 설치 파일을 같은 GitHub Release 또는
배포 디렉터리에 함께 게시한다.

이 저장소의 분리는 라이선스 의무를 회피하기 위한 것이 아니다. 적용되는
오픈소스 라이선스와 H.264/HEVC 특허 라이선스는 배포 전에 별도로 검토해야 한다.
이 문서는 법률 자문이 아니다.
