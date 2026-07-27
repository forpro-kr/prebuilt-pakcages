# License and repository boundary

## 소유 범위

이 저장소가 다음 항목을 소유한다.

- GPL 옵션으로 빌드한 FFmpeg 및 libx264/libx265 runtime
- 고정한 upstream revision과 재현용 build manifest
- 사용한 전체 대응 소스, 패치 및 빌드 스크립트의 source archive
- FFmpeg, x264, x265 라이선스 원문과 제3자 고지
- ZIP 패키지, NSIS 스크립트 및 선택 설치 프로그램

제품 저장소는 런타임 검색, 기능 감지, 설치 링크와 외부 산출물 소비 계약만
소유한다. 제품 기본 설치 파일에 이 저장소의 GPL runtime을 자동으로 합치지 않는다.

## 배포 불변 조건

1. 바이너리와 정확히 일치하는 revision 및 configure flags를 manifest에 기록한다.
2. FFmpeg `COPYING.GPLv2`, x264 `COPYING`, x265 `COPYING` 원문을 패키지와 함께 둔다.
3. FFmpeg/x264/x265 전체 대응 소스와 이 저장소의 빌드·패키징 스크립트를 source
   archive로 제공한다.
4. manifest에 기록한 모든 runtime의 SHA-256을 생성하고 설치 전에 검사한다.
5. NSIS 설치는 사용자 범위의 고정 경로에 수행하며 uninstall entry를 등록한다.
6. GPL runtime을 별도 다운로드로 제공해도 라이선스 의무가 사라진다고 주장하지 않는다.

상용 배포 전에는 FFmpeg의 legal 안내와 각 upstream의 COPYING을 기준으로 법무
검토를 수행한다. H.264/HEVC 특허 풀 또는 지역별 특허 문제는 오픈소스
저작권 라이선스와 별개의 검토 항목이다.
