// Copyright (c) 2019-2022 Alibaba Cloud
// Copyright (c) 2019-2022 Ant Group
//
// SPDX-License-Identifier: Apache-2.0
//

use crate::types::{
    ContainerConfig, ContainerID, ContainerProcess, ExecProcessRequest, KillRequest,
    ProcessExitStatus, ProcessStateInfo, ResizePTYRequest, ShutdownRequest, StatsInfo,
    UpdateRequest, PID,
};
use anyhow::Result;
use async_trait::async_trait;
use oci_spec::runtime as oci;

#[async_trait]
pub trait ContainerManager: Send + Sync {
    // container lifecycle
    async fn create_container(&self, config: ContainerConfig, spec: oci::Spec) -> Result<PID>;
    async fn pause_container(&self, container_id: &ContainerID) -> Result<()>;
    async fn resume_container(&self, container_id: &ContainerID) -> Result<()>;
    async fn stats_container(&self, container_id: &ContainerID) -> Result<StatsInfo>;
    async fn update_container(&self, req: UpdateRequest) -> Result<()>;
    async fn connect_container(&self, container_id: &ContainerID) -> Result<PID>;

    // process lifecycle
    async fn close_process_io(&self, process_id: &ContainerProcess) -> Result<()>;
    async fn delete_process(&self, process_id: &ContainerProcess) -> Result<ProcessStateInfo>;
    async fn exec_process(&self, req: ExecProcessRequest) -> Result<()>;
    async fn kill_process(&self, req: &KillRequest) -> Result<()>;
    async fn resize_process_pty(&self, req: &ResizePTYRequest) -> Result<()>;
    async fn start_process(&self, process_id: &ContainerProcess) -> Result<PID>;
    async fn state_process(&self, process_id: &ContainerProcess) -> Result<ProcessStateInfo>;
    async fn wait_process(&self, process_id: &ContainerProcess) -> Result<ProcessExitStatus>;

    // utility
    async fn pid(&self) -> Result<PID>;
    async fn need_shutdown_sandbox(&self, req: &ShutdownRequest) -> bool;
    async fn is_sandbox_container(&self, process_id: &ContainerProcess) -> bool;
    async fn has_guest_container(&self, process_id: &ContainerProcess) -> bool;
    async fn guest_map_is_empty(&self) -> bool;
}

/// Leftover Unknown init: kubelet StopContainer of a CRI id that never
/// entered the shim map (e.g. `fetch-certs` after a node reboot). Wait
/// then errors and never reaches sandbox-id Kill. An empty guest map
/// (no workload containers; the pause/sandbox entry does not count —
/// fix21) means only the pause/QEMU remain — safe to stop. Do **not**
/// stop when another guest container is still in the map (init
/// CrashLoop retry).
pub fn should_stop_vm_on_missing_task(
    is_sandbox: bool,
    is_container_process: bool,
    has_guest_container: bool,
    guest_map_is_empty: bool,
) -> bool {
    // T15: containerd registers the sandbox/pause task with the QEMU pid.
    // StopPodSandbox Kills that id; the shim has no guest container for it,
    // so nobody would call stop() and Wait would block on the live QEMU.
    if is_sandbox {
        return true;
    }
    // T16: CRI Kills/Waits a container that never entered the shim map
    // (leftover Unknown init after a node reboot). Only stop the VM when
    // no guest workload container remains.
    is_container_process && !has_guest_container && guest_map_is_empty
}
