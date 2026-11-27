# HYSTERoC: A Hysteresis-Controlled Hybrid Routing for NoC

**A Lightweight Approach to Suppressing Routing-Mode Oscillations Under Dynamic Congestion**

* **Course / Requirement:** Mini Project `[23EC5PWMPR]` (Submitted in partial fulfillment of the requirement for completion)

* **Department:** Department of Electronics and Communication Engineering

* **Institution:** B.M.S. College of Engineering (Autonomous College, affiliated to Visvesvaraya Technological University, Belgaum)

* **Address:** Bull Temple Road, Basavanagudi, Bengaluru – 560019

* **Academic Year:** 2026–2027

### Submitted By

| Student Name | USN | 
| ----- | ----- | 
| **Ratik Agrawal** | `1BF24EC118` | 
| **Rohit Nair** | `1BF24EC121` | 
| **Sawan Kumar** | `1BF24EC136` | 
| **Shamik Joshi** | `1BF24EC138` | 

### Under the Guidance Of

* **Prof. Ajaykumar Devarapalli**, Assistant Professor, Dept. of ECE, BMSCE

## Area of Application / Domain

VLSI Design and Embedded Systems, specifically, Network-on-Chip (NoC) architecture, digital design (RTL/FPGA implementation), and computer interconnection networks. The work falls within the broader domains of System-on-Chip (SoC) communication infrastructure and reconfigurable hardware design.

## Introduction

The continued scaling of multi-core and many-core System-on-Chip (SoC) architectures has made on-chip communication a primary determinant of overall system performance, rendering traditional shared-bus interconnects inadequate beyond a small number of cores. Network-on-Chip (NoC) architectures address this limitation by structuring on-chip communication as a packet-switched network of routers interconnected in a regular topology, most commonly a two-dimensional mesh \[1\].

The routing algorithm governing packet forwarding within a NoC directly determines its latency, throughput, and power characteristics. Deterministic routing algorithms, such as XY dimension-order routing, are simple to implement and inherently deadlock-free but exhibit severe throughput degradation under non-uniform or high-intensity traffic. Adaptive routing algorithms, such as the Odd-Even turn model, redistribute traffic around congested regions and thereby sustain higher throughput, but at the cost of increased control-logic complexity. Hybrid routing architectures attempt to obtain the benefits of both approaches by dynamically switching between deterministic and adaptive modes based on a measured congestion metric \[13\].

Existing hybrid routers, however, rely on a single congestion threshold to govern this switching decision. When network traffic fluctuates near this threshold, the router oscillates rapidly and unproductively between routing modes, a phenomenon termed the "ping-pong effect," resulting in control instability, latency jitter, and wasted dynamic power without corresponding performance benefit. This project proposes and evaluates a dual-threshold, hysteresis-based switching mechanism, termed HYSTEROC, that eliminates this oscillatory behavior while preserving the responsiveness and hardware efficiency of existing hybrid NoC routers. The proposed design targets implementation and validation on a field-programmable gate array (FPGA) platform, encompassing simulation-based performance evaluation and hardware-level resource and timing characterization.

This work carries both a societal and an industrial relevance: NoC-based interconnects underlie nearly all contemporary multi-core processors, data-center accelerators, and embedded SoCs used in consumer electronics, automotive systems, and IoT devices. Improvements in routing efficiency and the elimination of unnecessary switching activity translate directly into reduced dynamic power consumption at the chip level, a factor of growing importance given the energy demands of large-scale computing infrastructure. The proposed hysteresis-based mechanism, together with its formal treatment as a switched dynamical system, further constitutes an original research contribution to the NoC routing literature, distinguishing this work from a standard laboratory-style replication of existing routing schemes.

## Literature Survey

A systematic review of existing work in NoC routing was conducted, spanning foundational interconnection-network theory, congestion-aware hybrid routing, deadlock-avoidance mechanisms, fault-tolerant and QoS-aware routing, and recent learning-based approaches.

### A. Foundational Interconnection Network Architectures

Dally and Towles \[1\] established the foundational principles of packet-switched on-chip interconnection networks, arguing that structured, router-based communication scales more effectively than shared-bus or point-to-point wiring as core counts increase. This work provides the architectural basis, including mesh topology, wormhole flow control, and router microarchitecture, adopted by nearly all subsequent NoC routing research, including the present work.

### B. Adaptive Routing and Deadlock Avoidance

The Odd-Even turn model, employed as the adaptive-mode routing algorithm in this project, is examined in the context of deadlock-avoidance strategies for two-dimensional mesh NoCs by Papaphilippou and Van Chu \[10\]. Their work demonstrates that partially adaptive routing restricted by turn prohibitions achieves deadlock freedom without requiring virtual channels, a property directly leveraged in the proposed HYSTEROC architecture to minimize hardware overhead.

### C. Congestion-Aware Hybrid Routing

Hu and Marculescu \[13\] introduced DyAD, the seminal congestion-aware hybrid routing scheme that switches between deterministic and adaptive routing based on a single buffer-occupancy threshold, reporting hardware overhead below seven percent relative to purely adaptive routers. Manzoor et al. \[2\] proposed PAAD, a partially adaptive, deadlock-free congestion-aware hybrid router for 2D mesh NoCs, extending the hybrid-switching concept with alternative congestion metrics. Mehranzadeh et al. \[6\] presented FADyAD, a fault- and congestion-aware extension of DyAD verified on FPGA hardware with a dedicated monitoring unit, confirming the practical feasibility of DyAD-family routers in real hardware. More recently, Ji and Yang \[7\] proposed PcaDAHR, a pre-congestion-aware deterministic-adaptive hybrid routing algorithm that anticipates congestion before it occurs by shifting the switching threshold pre-emptively. While each of these works refines the switching criterion or congestion metric, all rely fundamentally on a single threshold value, leaving the oscillatory switching behavior addressed by this project unresolved.

### D. Fault-Tolerant and QoS-Aware Routing

Yu et al. \[12\] proposed a priority-based, fault-tolerant, QoS-aware routing algorithm for scalable NoC architectures, demonstrating that reliability-oriented routing decisions can be integrated with performance-oriented ones without substantial throughput loss. Li et al. \[4\] addressed the co-optimization of fault tolerance and congestion awareness in 3D NoC architectures, indicating that congestion-aware switching mechanisms generalize meaningfully to three-dimensional network topologies.

### E. Emerging and Learning-Based Approaches

Recent literature has begun exploring reinforcement-learning-based routing, including a proximal policy optimization (PPO) approach to fault-tolerant, self-healing packet routing in 2D torus NoCs \[11\]. While such approaches demonstrate adaptability to dynamic fault and congestion conditions, they introduce substantial computational and hardware overhead relative to threshold-based mechanisms, motivating the lightweight, deterministic hysteresis-based approach adopted in this work. Complementarily, Scherrer et al. \[14\] examined the general problem of incentivizing stable path selection in internet architectures, providing conceptual grounding for why hysteresis-style stability mechanisms are broadly applicable to routing-stability problems beyond the NoC domain specifically.

**Identified Research Gap:** Across the reviewed literature, congestion-driven mode-switching in hybrid NoC routers is uniformly governed by a single threshold, or, in the most recent case \[7\], a pre-emptively shifted single threshold. None of the surveyed works employ a dual-threshold hysteresis band, and none provide a formal stability analysis of the switching mechanism itself. This gap directly motivates the proposed HYSTEROC architecture.

## Problem Definition

Existing hybrid NoC routers switch between deterministic and adaptive routing modes using a single congestion threshold applied to local buffer occupancy. When network traffic causes congestion to fluctuate near this threshold, a common occurrence under bursty or near-saturation traffic conditions, the router repeatedly and unnecessarily toggles between routing modes. This oscillatory behavior, referred to as the ping-pong effect, degrades control-plane stability, introduces latency jitter, and consumes dynamic power without yielding any corresponding improvement in network throughput. There is currently no established mechanism in the reviewed literature that suppresses this oscillation while retaining responsiveness to genuine, sustained congestion changes, nor a formal analytical treatment establishing that such a mechanism is provably stable.

### HYSTEROC: Suppressing the "Ping-Pong Effect" in NoC Routing

Hybrid NoC routers switch between **Deterministic** (fixed path) and **Adaptive** (congestion-aware) modes. **Conventional single-threshold switching** suffers from rapid, wasteful toggling ("ping-pong effect") due to traffic fluctuations. HYSTEROC introduces dual-threshold hysteresis for stable transitions and enhanced performance.

#### (a) Conventional Single-Threshold Switching — Ping-Pong Effect

```
Congestion Signal
  ^         /\      /\        /\  /\      /\      /\
  |        /  \    /  \      /  \/  \    /  \    /  \
T |-------*----*--*----*----*--------*--*----*--*----*--- (Threshold T)
  |      /      \/      \  /          \/      \/      \
  |  ___/                \/                            \___
  +--------------------------------------------------------> Time
         |    |  |    |    |        |  |    |  |    |
Mode:   [DET  |AD|DET |AD  |ADAPT   |DT|AD  |DT|AD  | DET ]
              └──┴────┴────┴────────┴──┴────┴──┴────┘
                 Rapid "Ping-Pong" Mode Toggling

```

```
stateDiagram-v2
    direction LR
    [*] --> DET
    DET --> ADAPT : Congestion > T (Zero Noise Margin)
    ADAPT --> DET : Congestion <= T (Immediate Revert)

```

* **Behavior:** Rapid, unnecessary switching between routing modes when traffic hovers near a single threshold.

* **High Resource Waste:** Chaotic mode toggling consumes computational resources and increases network latency without improving path selection.

* **Single-Threshold (**$T$**) Bottleneck:** A fixed switching point provides no margin for signal noise or minor congestion fluctuations.

#### (b) Proposed Dual-Threshold Hysteresis Switching — Oscillation Suppressed

```
Congestion Signal
       ^                  /\/\/\/\/\/\
T_high |---------------- /------------\------------- (Enter Adaptive)
       |  Hysteresis    /     Band     \
T_low  |--/\/--\-------/----------------\--/\/\----- (Exit Adaptive)
       | /      \     /                  \/    \
       +--------------------------------------------> Time
Mode:  [         DET         ][     ADAPT     ][ DET ] (Stable Transitions)

```

```
stateDiagram-v2
    direction LR
    [*] --> DET
    DET --> ADAPT : Congestion > T_high
    DET --> DET : Congestion <= T_high (Hysteresis Band)
    ADAPT --> DET : Congestion < T_low
    ADAPT --> ADAPT : Congestion >= T_low (Hysteresis Band)

```

* **Stable Mode Transitions:** Uses separate thresholds to enter ($T_{high}$) and exit ($T_{low}$) adaptive routing mode.

* **Oscillation Suppression:** The "gap" (Hysteresis Band) between thresholds prevents rapid toggling, ensuring cleaner and more meaningful mode changes.

* **Minimal FPGA Overhead:** Maintains deadlock freedom and performance with negligible increases in LUT, FF, and BRAM utilization.

*Figure 1: Comparison of single-threshold routing-mode oscillation and dual-threshold hysteresis suppression.*

## Proposed Solution

This project proposes HYSTEROC, a hybrid NoC router in which mode arbitration is governed by a dual-threshold hysteresis finite state machine (FSM) rather than a single threshold. An upper activation threshold ($T_{high}$) governs transition from deterministic to adaptive mode, while a distinct, lower deactivation threshold ($T_{low}$) governs the reverse transition. Congestion fluctuations within the resulting hysteresis band ($T_{high} - T_{low}$) do not trigger a mode switch, eliminating oscillation while preserving responsiveness to sustained congestion trends.

The router retains XY dimension-order routing as its deterministic mode and Odd-Even turn-model routing as its adaptive mode, both established, deadlock-free algorithms drawn directly from prior literature \[1\], \[10\], \[13\]. Local congestion is estimated using an exponentially weighted moving average (EWMA) of buffer occupancy rather than an instantaneous value, filtering short-term measurement noise that would otherwise drive spurious switching. The hysteresis FSM is additionally modeled as a switched dynamical system, following an analytical framework drawn from hysteresis-based control theory \[15\], to formally establish a minimum dwell time between mode transitions.

### Block Diagram: HYSTEROC Router Signal Flow

```
flowchart LR
    A["1. Packet Generation<br/>(Network traffic originates<br/>from the source)"] --> B["2. Packet Buffering<br/>(Incoming packets stored<br/>in FIFO buffers)"]
    B --> C["3. Buffer Monitoring<br/>(System continuously checks<br/>buffer occupancy levels)"]
    C --> D["4. EWMA Filtering<br/>(Buffer occupancy filtered<br/>via Exponentially Weighted<br/>Moving Average)"]
    D --> E["5. Hysteresis Control<br/>(FSM uses EWMA to<br/>control routing mode)"]
    E --> F["6. Mode Selection<br/>(Multiplexer switches<br/>between XY and Odd-Even<br/>based on control signal)"]
    F --> G["7a. Deterministic Routing<br/>(XY routing logic determines<br/>packet path deterministically)"]
    F --> H["7b. Adaptive Routing<br/>(Odd-Even routing logic<br/>adapts path based on<br/>network conditions)"]
    G --> I["8. Switch Allocation<br/>(Crossbar allocates switch<br/>resources to route packets)"]
    H --> I
    I --> J["9. Packet Delivery<br/>(Packets delivered to<br/>destination via output ports)"]

```

*Figure 2: HYSTEROC router signal flow and major functional blocks.*

## Project Execution Steps

The project is organized across four sequential technical phases, executed by a team of four members with overlapping responsibilities in RTL design, verification and hardware integration, network-level simulation, and documentation/theoretical analysis.

 1. Review of foundational and hybrid-routing literature; finalization of the design specification for the dual-threshold hysteresis mechanism.

 2. Implementation of the EWMA congestion monitor and register-programmable threshold interface in SystemVerilog.

 3. Implementation of the dual-threshold hysteresis finite state machine governing mode arbitration.

 4. Implementation of the XY and Odd-Even routing-compute blocks and the associated routing-mode multiplexer.

 5. Development of a unit-level verification testbench; validation of oscillation-free switching behavior using synthetic congestion traces, and validation of deadlock freedom under adversarial traffic patterns.

 6. Extension of the Noxim network-on-chip simulator to support dual-threshold hysteresis switching, including instrumentation of a per-router mode-transition counter.

 7. Execution of network-level simulation sweeps across $4 \times 4$ and $8 \times 8$ mesh topologies, multiple traffic patterns (Uniform Random, Transpose, Hotspot), and varying packet injection rates, benchmarked against deterministic, adaptive, and single-threshold hybrid baselines.

 8. Sensitivity analysis of the hysteresis margin ($T_{high} - T_{low}$) to characterize the tradeoff between switching stability and responsiveness.

 9. Synthesis of the proposed router and a single-threshold baseline on the provided FPGA platform; extraction and comparison of resource utilization (LUTs, flip-flops, BRAM) and maximum operating frequency.

10. Formal derivation of the minimum-dwell-time stability property and consolidation of the deadlock-freedom argument.

11. Consolidation of simulation and hardware results; preparation of the final project report and presentation.

### Project Execution Timeline & Milestones

```
gantt
    title HYSTEROC Project Execution Timeline (W1 - W13)
    dateFormat  YYYY-MM-DD
    axisFormat  %d %b

    section Milestones
    Synopsis Review (W1 Start)           :milestone, m1, 2026-09-24, 0d
    Unit-Level Design Freeze (End W4)    :milestone, m2, 2026-10-22, 0d
    Mid Review (W7)                      :milestone, m3, 2026-11-06, 0d
    Network-Level Results Complete (W8)  :milestone, m4, 2026-11-19, 0d
    Integrated Draft Complete (End W11)  :milestone, m5, 2026-12-10, 0d
    Final Review (W13 End)               :milestone, m6, 2026-12-24, 0d

    section RTL Design
    Finalize design spec                 :rtl1, 2026-09-24, 7d
    Implement EWMA congestion monitor    :rtl2, 2026-10-01, 7d
    Implement hysteresis FSM             :rtl3, 2026-10-08, 7d
    Implement XY/OE routing-compute + mux:rtl4, 2026-10-15, 7d
    RTL bug-fixing support               :rtl5, 2026-10-22, 7d
    RTL integration freeze               :rtl6, 2026-10-29, 7d
    Support integration issues           :rtl7, 2026-11-19, 14d
    Final integration check              :rtl8, 2026-12-12, 12d

    section Verification & FPGA Integration
    Develop unit testbench               :ver1, 2026-10-15, 10d
    Deadlock stress test                 :ver2, 2026-10-25, 4d
    Vivado synthesis (router vs baseline):ver3, 2026-11-22, 9d
    Extract resource/timing reports      :ver4, 2026-12-01, 6d
    Optional: small mesh synthesis       :ver5, 2026-12-03, 4d
    Final synthesis verification         :ver6, 2026-12-12, 12d

    section Simulation & Evaluation
    Noxim setup + dual-threshold ext.    :sim1, 2026-10-01, 10d
    Instrument mode-transition counter   :sim2, 2026-10-15, 6d
    Baseline sweeps (4x4 mesh)           :sim3, 2026-10-29, 7d
    Full HYSTEROC sweeps (8x8, all traffic):sim4, 2026-11-05, 14d
    Hysteresis-margin sensitivity sweep  :sim5, 2026-11-15, 4d
    Consolidate data into figures        :sim6, 2026-11-22, 11d
    Final data sanity pass               :sim7, 2026-12-12, 4d

    section Documentation & Theoretical Analysis
    Literature survey + synopsis writing :doc1, 2026-09-24, 7d
    Draft problem statement + dwell-time :doc2, 2026-10-01, 7d
    Draft deadlock-freedom argument      :doc3, 2026-10-08, 7d
    Draft stability-proof section        :doc4, 2026-10-22, 10d
    Prepare Mid Review presentation      :doc5, 2026-11-01, 9d
    Write Proposed Solution/Results      :doc6, 2026-11-19, 21d
    Final report polish + rehearsal      :doc7, 2026-12-12, 12d

```

*Figure 3: Project execution timeline and review milestones.*

## Estimated Bill of Materials

| S.No. | Item | Specification | Source/Provider | Estimated Cost | 
| ----- | ----- | ----- | ----- | ----- | 
| 1 | FPGA Development Board | Xilinx/Zynq-series (as allotted) | Provided by institution | Nil | 
| 2 | Host PC / Workstation | For Vivado toolchain and simulation | Provided by institution (lab) | Nil | 
| 3 | USB/JTAG Programming Cable | Board-specific, typically bundled | Provided by institution (with board) | Nil | 
| 4 | Vivado Design Suite | RTL synthesis and implementation | Free WebPACK edition / institution license | Nil | 
| 5 | Noxim Simulator | Cycle-accurate NoC simulation (SystemC) | Open-source | Nil | 
| 6 | Miscellaneous (power adapter, USB cables) | Standard accessories | Provided by institution (with board) | Nil | 

*Note: All hardware and software resources required for this project are provided by the institution or are available as open-source tools; no external procurement is required.*

## References

 1. W. J. Dally and B. Towles, "Route packets, not wires: On-chip interconnection networks," in *Proc. 38th Design Automation Conf. (DAC)*, 2001, doi: `10.1109/DAC.2001.156225`.

 2. M. Manzoor, R. N. Mir, and N.-ud-d. Hakim, "PAAD (partially adaptive and deterministic routing): A deadlock free congestion aware hybrid routing for 2D mesh network-on-chips," *Microprocessors and Microsystems*, vol. 92, Art. no. 104551, 2022, doi: `10.1016/j.micpro.2022.104551`.

 3. M. T. Balakrishnan, T. G. Venkatesh, and A. Vijaya Bhaskar, "Design and implementation of congestion aware router for network-on-chip," *Integration*, vol. 88, pp. 43-57, 2023, doi: `10.1016/j.vlsi.2022.08.012`.

 4. J. Li, C. Qin, and X. Sun, "An efficient adaptive routing algorithm for the co-optimization of fault tolerance and congestion awareness based on 3D NoC," *Microelectronics Journal*, vol. 142, Art. no. 105989, 2023, doi: `10.1016/j.mejo.2023.105989`.

 5. D. Venkatesh, D. G. Srujana, A. Raghuraman, D. Divya Ratna, and B. Rajeshwari, "LORV: Latency-optimized routing for NoC with virtual channels in 2D mesh," in *Proc. IEEE Int. Conf. Electronics, Computing and Communication Systems (ECCS)*, 2024, doi: `10.1109/ECCS63650.2024.00009`.

 6. A. Mehranzadeh, A. Khademzadeh, and A. Mehran, "FADyAD: Fault and congestion aware routing algorithm based on DyAD algorithm," Iran Telecommunication Research Center and Islamic Azad University, Tech. Rep., 2008.

 7. N. Ji and Y. Yang, "A pre-congestion-aware deterministic-adaptive hybrid routing (PcaDAHR) algorithm for network-on-chip," *Microelectronics Journal*, vol. 164, Art. no. 106811, 2025, doi: `10.1016/j.mejo.2025.106811`.

 8. A. Lit, M. H. Husin, and S. Suhaili, "Performance and energy evaluation of dynamic adaptive deterministic routing algorithm for multicore architectures," *e-Prime: Advances in Electrical Engineering, Electronics and Energy*, vol. 9, Art. no. 100716, 2024, doi: `10.1016/j.prime.2024.100716`.

 9. P. P. Dere, S. S. Ashtekar, E. Sarda, and B. S. Deore, "Performance evaluation of network-on-chip routing algorithms across multiple traffic scenarios," *International Research Journal of Multidisciplinary Technovation*, vol. 8, no. 2, pp. 151-165, 2026, doi: `10.54392/irjmt2629`.

10. P. Papaphilippou and T. Van Chu, "Efficient deadlock avoidance for 2-D mesh NoCs that use OQ or VOQ routers," *IEEE Transactions on Computers*, vol. 73, no. 5, pp. 1414-1426, 2024, doi: `10.1109/TC.2024.3365954`.

11. M. W. Charrwi and Z. Hussain, "Toward self-healing networks-on-chip: RL-driven routing in 2D torus architectures," High Performance Computing Lab, Kuwait University, unpublished manuscript, 2025.

12. X. Yu, L. Tang, J. Mi, J. Liu, and L. Long, "Fault tolerant and quality of service aware routing algorithm based on priority technique for scalable network on chip architectures," *Scientific Reports*, vol. 15, Art. no. 36578, 2025, doi: `10.1038/s41598-025-20381-3`.

13. J. Hu and R. Marculescu, "DyAD: Smart routing for networks-on-chip," in *Proc. 41st Design Automation Conf. (DAC)*, 2004, pp. 260-263, doi: `10.1145/996566.996638`.

14. S. Scherrer, M. Legner, A. Perrig, and S. Schmid, "Incentivizing stable path selection in future Internet architectures," *Performance Evaluation*, vol. 144, Art. no. 102137, 2020, doi: `10.1016/j.peva.2020.102137`.

15. M. Thielmann and F. Hans, "Hysteresis-based current control approach by means of the theory of switched systems," *Applied Sciences*, vol. 11, no. 19, Art. no. 9175, 2021, doi: `10.3390/app11199175`.