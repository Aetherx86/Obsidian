# Obsidian

듀얼 타깃 마이크로 JIT 머신 코드 어셈블러 (Dual-Target Micro-JIT Machine Code Assembler)

순수 Zig로 작성된 듀얼 아키텍처(x86_64 / AArch64) 마이크로 JIT 머신 코드 어셈블러 및 동적 실행 엔진입니다.

[English Documentation](README.md)

## 개요

Obsidian은 외부 의존성이 전혀 없는 베어메탈 중간 표현(IR) 로우어링 계층을 제공합니다. 메모리 버퍼에 유효한 기계어 바이트를 직접 방출하고, 메모리 보호 플래그를 쓰기 가능에서 실행 가능으로 전환한 뒤, 3나노초 미만의 호출 오버헤드로 네이티브 함수 포인터를 디스패치합니다.

## 아키텍처

- **듀얼 아키텍처 이미터 (Dual-Architecture Emitter)**: x86_64(Intel/AMD) 및 AArch64(Apple Silicon / ARMv8+) 전 타깃을 위한 네이티브 기계어 인스트럭션을 직접 인코딩합니다.
- **실행 가능 페이지 관리자 (Executable Page Manager)**: POSIX `mmap`을 통해 페이지 정렬 메모리 영역을 할당하고 쓰기 배리어를 적용한 뒤, `mprotect`로 실행 권한을 전환합니다.
- **런타임 무의존성 (Zero Runtime Dependencies)**: LLVM, Dynasm 또는 C 컴파일러 툴체인 의존성 없이 완전히 독립적으로 작동합니다.

## 성능

- **호출 오버헤드 (Invocation Latency)**: Apple Silicon Mac에서 JIT 호출당 약 0.7~1.2ns, GitHub ubuntu x86_64 러너에서 약 1.1ns (`obsidian bench --json`의 `call_overhead_ns`).
- **컴파일 속도 (Compile Speed)**: 벤치마크 프로그램의 최적화, 레지스터 할당, 코드 생성에 약 19마이크로초 (`compile_us`). JIT 코드는 IR 인터프리터보다 약 30배 빠릅니다.

## 빌드 및 사용법

```bash
# 단위 테스트 실행
zig build test

# 최적화 바이너리 빌드
zig build -Doptimize=ReleaseFast

# JIT 컴파일된 곱셈 함수 어셈블 및 실행
./zig-out/bin/obsidian exec mul 7 6

# JIT 실행 오버헤드 벤치마크
./zig-out/bin/obsidian bench
```

## 0.2.0 변경 사항

- 정수 IR(레이블, 점프, 비교 분기, 비교 연산, 시프트, 비트 연산, 최대 6개 인자의 호스트 함수 호출)과 검증기, 경로 기반 미정의 변수 사용 검사를 추가했습니다.
- 최적화기: 상수 폴딩과 대수적 단순화, 복사 전파, 분기 폴딩, 도달 불가능 코드 제거, 데드 코드 제거를 고정점까지 반복합니다.
- 선형 스캔 레지스터 할당기: 호출을 가로지르는 값은 callee-saved 레지스터만 사용하며, 레지스터가 부족하면 스택 슬롯으로 스필하고 할당 결과를 검증합니다.
- x86_64(System V)와 AArch64(AAPCS64) 코드 생성기: 스택 프레임, 스필 슬롯, 분기 패치, 매개변수와 호출 인자의 병렬 이동을 처리하며 어느 호스트에서든 두 타깃 모두 생성할 수 있습니다.
- W^X 실행 메모리: macOS/AArch64에서는 `MAP_JIT`, `pthread_jit_write_protect_np`, `sys_icache_invalidate`를 사용하고, 그 밖의 환경에서는 결과를 확인하는 `mprotect` RW에서 RX 전환과 AArch64용 `__clear_cache`를 사용합니다.
- CLI 하위 명령: `run`(`--check`, `--interp`, `--no-opt`, `--regs`), `dump`(디스어셈블리 형식 목록), `fuzz`(차등 테스트, `--json`), `bench --json`, `version`.
- 인터프리터, 최적화된 인터프리터, 네이티브 코드를 무작위 프로그램으로 비교하는 차등 테스트와 두 명령어 집합의 골든 바이트 테스트를 추가했습니다.

```bash
./zig-out/bin/obsidian run examples/collatz.oir 27 --check
./zig-out/bin/obsidian dump examples/fib.oir --target x86_64
./zig-out/bin/obsidian fuzz --seed 7 --count 20000
./zig-out/bin/obsidian bench --json
```

## 라이선스

MIT License. Copyright (c) 2026 Jeong Hoon Kim.
