use std::sync::Arc;
use tokio::sync::Mutex;
use tokio::time::Duration;

pub struct RPerfServer {
    config: Arc<Config>,
    target_pollers: Arc<Mutex<Vec<TargetPoller>>>,
}

impl RPerfServer {
    pub async fn start(&self) -> Result<ServerHandle> {
        let addr: SocketAddr = self.config.listen_addr.parse()
            .context("Failed to parse listen address")?;

        info!("Starting rperf gRPC server on {}", addr);

        let pollers = self.target_pollers.clone();
        let config = self.config.clone();

        // Spawn a single task to run all tests sequentially
        let poller_handle = tokio::spawn(async move {
            loop {
                let mut pollers = pollers.lock().await;
                for poller in pollers.iter_mut() {
                    info!("Running test for target: {}", poller.target_name());
                    match poller.run_single_test().await {
                        Ok(result) => {
                            if result.success {
                                info!("Test for target '{}' completed: {:.2} Mbps", 
                                    poller.target_name(), result.summary.bits_per_second / 1_000_000.0);
                            } else {
                                warn!("Test for target '{}' failed: {}", 
                                    poller.target_name(), result.error.as_deref().unwrap_or("Unknown error"));
                            }
                        },
                        Err(e) => error!("Error running test for target '{}': {}", poller.target_name(), e),
                    }
                    // Wait before the next test
                    tokio::time::sleep(Duration::from_secs(poller.config.poll_interval)).await;
                }
                // Optional: Small delay between full cycles if needed
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        });

        let service = RPerfServiceImpl {
            config: self.config.clone(),
            target_pollers: self.target_pollers.clone(),
        };

        let server_handle = tokio::spawn(async move {
            Server::builder()
                .add_service(RPerfServiceServer::new(service))
                .serve(addr)
                .await
                .context("gRPC server error")?;
            Ok(())
        });

        Ok(ServerHandle {
            join_handle: server_handle,
            pollers: self.target_pollers.clone(),
        })
    }
}

// Update ServerHandle to include poller handle
pub struct ServerHandle {
    join_handle: JoinHandle<Result<()>>,
    poller_handle: JoinHandle<()>,
    pollers: Arc<Mutex<Vec<TargetPoller>>>,
}

impl ServerHandle {
    pub async fn stop(self) -> Result<()> {
        self.join_handle.abort();
        self.poller_handle.abort();
        for poller in self.pollers.lock().await.iter_mut() {
            poller.stop().await?;
        }
        match self.join_handle.await {
            Ok(result) => result,
            Err(e) if e.is_cancelled() => Ok(()),
            Err(e) => Err(anyhow::anyhow!("Server task failed: {}", e)),
        }
    }
}