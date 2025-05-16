/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package discovery

import (
	"context"
	"log"
	"time"

	"github.com/carverauto/serviceradar/proto"
)

// GRPCDiscoveryService implements the gRPC interface for the discovery service
type GRPCDiscoveryService struct {
	proto.UnimplementedDiscoveryServiceServer
	engine DiscoveryEngine
}

// NewGRPCDiscoveryService creates a new gRPC discovery service
func NewGRPCDiscoveryService(engine DiscoveryEngine) *GRPCDiscoveryService {
	return &GRPCDiscoveryService{
		engine: engine,
	}
}

// GetStatus implements the DiscoveryService interface
func (s *GRPCDiscoveryService) GetStatus(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	log.Printf("Received GetStatus request: %v", req)

	// If a discovery ID is provided, get status for that job
	if req.DiscoveryId != "" {
		status, err := s.engine.GetDiscoveryStatus(ctx, req.DiscoveryId)
		if err != nil {
			return nil, err
		}

		return &proto.StatusResponse{
			Available:         true,
			Status:            statusTypeToString(status.Status),
			ActiveDiscoveries: []string{req.DiscoveryId},
			PendingJobs:       0,
			CompletedJobs:     0,
		}, nil
	}

	// Otherwise get overall service status
	// In a real implementation, you would track active, pending, and completed jobs
	return &proto.StatusResponse{
		Available:         true,
		Status:            "running",
		ActiveDiscoveries: []string{}, // In a real implementation, this would list active job IDs
		PendingJobs:       0,
		CompletedJobs:     0,
	}, nil
}

// StartDiscovery implements the DiscoveryService interface
func (s *GRPCDiscoveryService) StartDiscovery(ctx context.Context, req *proto.DiscoveryRequest) (*proto.DiscoveryResponse, error) {
	log.Printf("Received StartDiscovery request: %v", req)

	// Convert proto request to internal params
	params := &DiscoveryParams{
		Seeds:       req.Seeds,
		Type:        protoToDiscoveryType(req.Type),
		Credentials: protoToSNMPCredentials(req.Credentials),
		Options:     req.Options,
		Concurrency: int(req.Concurrency),
		Timeout:     time.Duration(req.TimeoutSeconds) * time.Second,
		Retries:     int(req.Retries),
		AgentID:     req.AgentId,
		PollerID:    req.PollerId,
	}

	// Start discovery
	discoveryID, err := s.engine.StartDiscovery(ctx, params)
	if err != nil {
		return nil, err
	}

	return &proto.DiscoveryResponse{
		DiscoveryId:       discoveryID,
		Success:           true,
		Message:           "Discovery started successfully",
		EstimatedDuration: estimateDuration(params),
	}, nil
}

// GetDiscoveryResults implements the DiscoveryService interface
func (s *GRPCDiscoveryService) GetDiscoveryResults(ctx context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	log.Printf("Received GetDiscoveryResults request: %v", req)

	// Get results from engine
	results, err := s.engine.GetDiscoveryResults(ctx, req.DiscoveryId, req.IncludeRawData)
	if err != nil {
		return nil, err
	}

	// Convert to proto response
	status := statusTypeToProtoStatus(results.Status.Status)

	// Convert devices
	protoDevices := make([]*proto.DiscoveredDevice, len(results.Devices))
	for i, device := range results.Devices {
		protoDevices[i] = &proto.DiscoveredDevice{
			Ip:          device.IP,
			Mac:         device.MAC,
			Hostname:    device.Hostname,
			SysDescr:    device.SysDescr,
			SysObjectId: device.SysObjectID,
			SysContact:  device.SysContact,
			SysLocation: device.SysLocation,
			Uptime:      device.Uptime,
			Metadata:    device.Metadata,
		}
	}

	// Convert interfaces
	protoInterfaces := make([]*proto.DiscoveredInterface, len(results.Interfaces))
	for i, iface := range results.Interfaces {
		protoInterfaces[i] = &proto.DiscoveredInterface{
			DeviceIp:      iface.DeviceIP,
			IfIndex:       int32(iface.IfIndex),
			IfName:        iface.IfName,
			IfDescr:       iface.IfDescr,
			IfAlias:       iface.IfAlias,
			IfSpeed:       iface.IfSpeed,
			IfPhysAddress: iface.IfPhysAddress,
			IpAddresses:   iface.IPAddresses,
			IfAdminStatus: int32(iface.IfAdminStatus),
			IfOperStatus:  int32(iface.IfOperStatus),
			IfType:        int32(iface.IfType),
			Metadata:      iface.Metadata,
		}
	}

	// Convert topology links
	protoLinks := make([]*proto.TopologyLink, len(results.TopologyLinks))
	for i, link := range results.TopologyLinks {
		protoLinks[i] = &proto.TopologyLink{
			Protocol:           link.Protocol,
			LocalDeviceIp:      link.LocalDeviceIP,
			LocalIfIndex:       int32(link.LocalIfIndex),
			LocalIfName:        link.LocalIfName,
			NeighborChassisId:  link.NeighborChassisID,
			NeighborPortId:     link.NeighborPortID,
			NeighborPortDescr:  link.NeighborPortDescr,
			NeighborSystemName: link.NeighborSystemName,
			NeighborMgmtAddr:   link.NeighborMgmtAddr,
			Metadata:           link.Metadata,
		}
	}

	return &proto.ResultsResponse{
		DiscoveryId: req.DiscoveryId,
		Status:      status,
		Devices:     protoDevices,
		Interfaces:  protoInterfaces,
		Topology:    protoLinks,
		Error:       results.Status.Error,
		Progress:    float32(results.Status.Progress),
	}, nil
}

// Helper functions to convert between types

// protoToDiscoveryType converts a proto discovery type to an internal discovery type
func protoToDiscoveryType(typ proto.DiscoveryRequest_DiscoveryType) DiscoveryType {
	switch typ {
	case proto.DiscoveryRequest_FULL:
		return DiscoveryTypeFull
	case proto.DiscoveryRequest_BASIC:
		return DiscoveryTypeBasic
	case proto.DiscoveryRequest_INTERFACES:
		return DiscoveryTypeInterfaces
	case proto.DiscoveryRequest_TOPOLOGY:
		return DiscoveryTypeTopology
	default:
		return DiscoveryTypeFull
	}
}

// protoToSNMPCredentials converts proto SNMP credentials to internal SNMP credentials
func protoToSNMPCredentials(creds *proto.SNMPCredentials) SNMPCredentials {
	if creds == nil {
		return SNMPCredentials{
			Version: SNMPVersion2c,
		}
	}

	result := SNMPCredentials{
		Community:       creds.Community,
		Username:        creds.Username,
		AuthProtocol:    creds.AuthProtocol,
		AuthPassword:    creds.AuthPassword,
		PrivacyProtocol: creds.PrivacyProtocol,
		PrivacyPassword: creds.PrivacyPassword,
	}

	// Set version
	switch creds.Version {
	case proto.SNMPCredentials_V1:
		result.Version = SNMPVersion1
	case proto.SNMPCredentials_V2C:
		result.Version = SNMPVersion2c
	case proto.SNMPCredentials_V3:
		result.Version = SNMPVersion3
	}

	// Convert target-specific credentials
	if len(creds.TargetSpecific) > 0 {
		result.TargetSpecific = make(map[string]SNMPCredentials)

		for target, targetCreds := range creds.TargetSpecific {
			result.TargetSpecific[target] = protoToSNMPCredentials(targetCreds)
		}
	}

	return result
}

// statusTypeToString converts an internal status type to a string
func statusTypeToString(status DiscoveryStatusType) string {
	return string(status)
}

// statusTypeToProtoStatus converts an internal status type to a proto status enum
func statusTypeToProtoStatus(status DiscoveryStatusType) proto.DiscoveryStatus {
	switch status {
	case DiscoveryStatusPending:
		return proto.DiscoveryStatus_PENDING
	case DiscoveryStatusRunning:
		return proto.DiscoveryStatus_RUNNING
	case DiscoveryStatusCompleted:
		return proto.DiscoveryStatus_COMPLETED
	case DiscoveryStatusFailed:
		return proto.DiscoveryStatus_FAILED
	case DiscoveryStatusCancelled:
		return proto.DiscoveryStatus_CANCELLED
	default:
		return proto.DiscoveryStatus_UNKNOWN
	}
}

// estimateDuration estimates the duration of a discovery job based on parameters
func estimateDuration(params *DiscoveryParams) int32 {
	// This is a rough estimate - in a real implementation, you would use more factors
	seeds := len(params.Seeds)

	// Estimate number of devices
	estimatedDevices := seeds * 10 // Assume each seed leads to about 10 devices

	// Base time per device based on discovery type
	var timePerDevice int
	switch params.Type {
	case DiscoveryTypeFull:
		timePerDevice = 10 // seconds
	case DiscoveryTypeBasic:
		timePerDevice = 2
	case DiscoveryTypeInterfaces:
		timePerDevice = 5
	case DiscoveryTypeTopology:
		timePerDevice = 5
	default:
		timePerDevice = 10
	}

	// Adjust for concurrency
	concurrency := params.Concurrency
	if concurrency <= 0 {
		concurrency = 10 // Default
	}

	// Total time = (estimated devices * time per device) / concurrency
	totalTime := (estimatedDevices * timePerDevice) / concurrency

	// Add some overhead
	totalTime = int(float64(totalTime) * 1.2)

	return int32(totalTime)
}
