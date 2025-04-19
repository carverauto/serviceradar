// src/components/Metrics/error-components.jsx
import React from 'react';
import { AlertTriangle, RefreshCw, HelpCircle } from 'lucide-react';

// Error message component with retry option
export const ErrorMessage = ({
                                 title = "Something went wrong",
                                 message = "We couldn't load the metrics data.",
                                 onRetry
                             }) => {
    return (
        <div className="bg-gray-800 border border-red-900/30 rounded-lg p-5 text-gray-300">
            <div className="flex items-start">
                <AlertTriangle className="text-red-500 mr-3 mt-1 flex-shrink-0" />
                <div>
                    <h3 className="font-semibold text-red-400 mb-1">{title}</h3>
                    <p className="text-sm text-gray-400 mb-3">{message}</p>

                    <div className="flex space-x-3">
                        {onRetry && (
                            <button
                                onClick={onRetry}
                                className="px-3 py-1.5 bg-gray-700 hover:bg-gray-600 text-sm rounded flex items-center transition-colors"
                            >
                                <RefreshCw size={14} className="mr-2" />
                                Try again
                            </button>
                        )}

                        <button
                            onClick={() => window.open('/docs/metrics-troubleshooting', '_blank')}
                            className="px-3 py-1.5 bg-gray-700/50 hover:bg-gray-600/50 text-sm rounded flex items-center transition-colors"
                        >
                            <HelpCircle size={14} className="mr-2" />
                            Get help
                        </button>
                    </div>
                </div>
            </div>
        </div>
    );
};

// Empty state component when no data is available
export const EmptyState = ({
                               message = "No metrics data available",
                               icon = AlertTriangle,
                               onAction,
                               actionLabel = "Refresh"
                           }) => {
    const Icon = icon;

    return (
        <div className="bg-gray-800 rounded-lg p-8 flex flex-col items-center justify-center text-center">
            <Icon className="text-gray-500 mb-3" size={32} />
            <p className="text-gray-400 mb-4">{message}</p>

            {onAction && (
                <button
                    onClick={onAction}
                    className="px-4 py-2 bg-blue-600 hover:bg-blue-700 rounded-md text-white transition-colors"
                >
                    {actionLabel}
                </button>
            )}
        </div>
    );
};

// Partial error indicator that shows in a card when just one metric type fails
export const PartialErrorIndicator = ({ metricName, onRetry }) => {
    return (
        <div className="mt-2 flex items-center justify-between text-xs">
            <div className="flex items-center text-amber-400">
                <AlertTriangle size={12} className="mr-1" />
                <span>Error loading {metricName} data</span>
            </div>

            {onRetry && (
                <button
                    onClick={onRetry}
                    className="text-blue-400 hover:text-blue-300 flex items-center"
                >
                    <RefreshCw size={10} className="mr-1" />
                    Retry
                </button>
            )}
        </div>
    );
};

// Loading state component
export const LoadingState = ({ message = "Loading metrics data..." }) => {
    return (
        <div className="bg-gray-800 rounded-lg p-8 flex flex-col items-center justify-center text-center">
            <div className="flex space-x-2 mb-4">
                <div className="w-2 h-2 rounded-full bg-blue-400 animate-bounce"></div>
                <div className="w-2 h-2 rounded-full bg-blue-400 animate-bounce delay-150"></div>
                <div className="w-2 h-2 rounded-full bg-blue-400 animate-bounce delay-300"></div>
            </div>
            <p className="text-gray-400">{message}</p>
        </div>
    );
};