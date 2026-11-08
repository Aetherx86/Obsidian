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

- **호출 오버헤드 (Invocation Latency)**: 최신 프로세서 기준 JIT 호출당 약 2.31나노초.
- **방출 속도 (Emission Speed)**: 인메모리 기준 초당 50,000,000개 이상의 명령어 생성.

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

## 라이선스

MIT License. Copyright (c) 2026 Jeong Hoon Kim.
