# 🛡️ SentinelSoC

**SentinelSoC** is a **security-centric edge System-on-Chip (SoC)** based on the **RISC-V** architecture.  
It is designed with **security as a first-class design goal**, integrating a hardware root of trust, secure boot, and **Information-Flow Tracking (IFT)** to enforce runtime data-flow security.

---

## About

SentinelSoC targets **edge and embedded deployments** where systems operate in **untrusted or partially trusted environments**. By combining secure boot with architectural support for information-flow tracking, the SoC provides strong guarantees on **code integrity**, **data confidentiality**, and **runtime security enforcement**.

---

## Key Features

- **RISC-V–Based Architecture**
  - Open, extensible ISA
  - Designed for auditability and research-driven security extensions

- **Hardware Root of Trust**
  - Immutable boot ROM
  - Cryptographic verification of the boot chain
  - Trust anchored in silicon

- **Secure Boot**
  - Authenticated and verified firmware execution
  - Protection against unauthorized code execution
  - Support for staged boot flows

- **Information-Flow Tracking (IFT)**
  - Hardware-assisted tracking of sensitive data
  - Runtime enforcement of data-flow security policies
  - Mitigation against data leakage and control-flow misuse

- **Edge-Oriented Design**
  - Lightweight and modular
  - Suitable for IoT and edge compute platforms
  - Designed with resource constraints in mind

---
