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

'use client';

import React, { useState } from 'react';
import { useAuth } from '@/components/AuthProvider';
import { Trash2, AlertTriangle, Loader } from 'lucide-react';
import { useRouter } from 'next/navigation';

interface DeleteDeviceButtonProps {
    deviceId: string;
    deviceName?: string;
    onDelete?: () => void;
}

const DeleteDeviceButton: React.FC<DeleteDeviceButtonProps> = ({
    deviceId,
    deviceName,
    onDelete
}) => {
    const { token } = useAuth();
    const router = useRouter();
    const [showConfirm, setShowConfirm] = useState(false);
    const [deleting, setDeleting] = useState(false);
    const [error, setError] = useState<string | null>(null);

    const handleDelete = async () => {
        setDeleting(true);
        setError(null);

        try {
            const response = await fetch(`/api/devices/${encodeURIComponent(deviceId)}`, {
                method: 'DELETE',
                headers: {
                    'Content-Type': 'application/json',
                    ...(token && { Authorization: `Bearer ${token}` })
                },
            });

            if (response.ok) {
                // Call onDelete callback if provided
                if (onDelete) {
                    onDelete();
                } else {
                    // Default behavior: redirect to devices list
                    router.push('/service/devices');
                }
            } else {
                const data = await response.json();
                setError(data.error || 'Failed to delete device');
                setDeleting(false);
                setShowConfirm(false);
            }
        } catch (err) {
            setError('Connection error');
            setDeleting(false);
            setShowConfirm(false);
        }
    };

    if (showConfirm) {
        return (
            <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-4">
                <div className="flex items-start space-x-3 mb-4">
                    <AlertTriangle className="h-6 w-6 text-red-600 dark:text-red-400 flex-shrink-0 mt-0.5" />
                    <div>
                        <h3 className="text-lg font-semibold text-red-900 dark:text-red-100 mb-1">
                            Confirm Device Deletion
                        </h3>
                        <p className="text-sm text-red-800 dark:text-red-200 mb-2">
                            Are you sure you want to delete{' '}
                            <span className="font-mono font-semibold">
                                {deviceName || deviceId}
                            </span>
                            ?
                        </p>
                        <p className="text-xs text-red-700 dark:text-red-300">
                            This will tombstone the device, marking it as deleted. This action can be reversed by
                            administrators if needed.
                        </p>
                    </div>
                </div>

                <div className="flex space-x-3">
                    <button
                        onClick={handleDelete}
                        disabled={deleting}
                        className="flex items-center space-x-2 px-4 py-2 bg-red-600 hover:bg-red-700 disabled:bg-red-400 text-white rounded-lg transition-colors"
                    >
                        {deleting ? (
                            <>
                                <Loader className="h-4 w-4 animate-spin" />
                                <span>Deleting...</span>
                            </>
                        ) : (
                            <>
                                <Trash2 className="h-4 w-4" />
                                <span>Yes, Delete Device</span>
                            </>
                        )}
                    </button>
                    <button
                        onClick={() => setShowConfirm(false)}
                        disabled={deleting}
                        className="px-4 py-2 bg-gray-200 dark:bg-gray-700 hover:bg-gray-300 dark:hover:bg-gray-600 disabled:bg-gray-100 dark:disabled:bg-gray-800 text-gray-900 dark:text-gray-100 rounded-lg transition-colors"
                    >
                        Cancel
                    </button>
                </div>

                {error && (
                    <div className="mt-3 p-3 bg-red-100 dark:bg-red-900/40 border border-red-300 dark:border-red-700 rounded text-sm text-red-800 dark:text-red-200">
                        {error}
                    </div>
                )}
            </div>
        );
    }

    return (
        <div>
            <button
                onClick={() => setShowConfirm(true)}
                className="flex items-center space-x-2 px-4 py-2 bg-red-600 hover:bg-red-700 text-white rounded-lg transition-colors"
            >
                <Trash2 className="h-4 w-4" />
                <span>Delete Device</span>
            </button>

            {error && (
                <div className="mt-3 p-3 bg-red-100 dark:bg-red-900/40 border border-red-300 dark:border-red-700 rounded text-sm text-red-800 dark:text-red-200">
                    {error}
                </div>
            )}
        </div>
    );
};

export default DeleteDeviceButton;
