## 1. Replace NATS with Phoenix PubSub in ConfigPublisher
- [ ] 1.1 Add Phoenix PubSub dependency/configuration if not already present
- [ ] 1.2 Update `publish_invalidation/3` to use `Phoenix.PubSub.broadcast/3`
- [ ] 1.3 Remove `publish_to_nats/2` private function
- [ ] 1.4 Remove NATS subject building logic

## 2. Update ConfigServer to subscribe to PubSub
- [ ] 2.1 Subscribe to invalidation topic in ConfigServer init
- [ ] 2.2 Handle PubSub messages to trigger cache invalidation
- [ ] 2.3 Ensure cluster-wide distribution works (nodes receive broadcasts)

## 3. Cleanup
- [ ] 3.1 Remove unused NATS-related imports from ConfigPublisher
- [ ] 3.2 Update module documentation to reflect PubSub usage
- [ ] 3.3 Verify no other code depends on NATS config invalidation subjects

## 4. Testing
- [ ] 4.1 Test local cache invalidation works
- [ ] 4.2 Test cluster-wide invalidation (if multi-node setup available)
- [ ] 4.3 Verify agents still receive config updates correctly
