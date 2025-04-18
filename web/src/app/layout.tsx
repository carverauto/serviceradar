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

// src/app/layout.tsx
import './globals.css';
import { Inter } from 'next/font/google';
import { Providers } from './providers';
import { AuthProvider } from '@/components/AuthProvider';

const inter = Inter({ subsets: ['latin'] });

export const metadata = {
    title: 'ServiceRadar',
    description: 'Monitor your network services',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
    return (
        <html lang="en" suppressHydrationWarning>
        <head>
            <link rel="icon" type="image/png" sizes="32x32" href="/favicons/favicon-32x32.png" />
            <link rel="icon" type="image/png" sizes="16x16" href="/favicons/favicon-16x16.png" />
            <link rel="shortcut icon" href="/favicons/favicon.ico" />
            <link rel="apple-touch-icon" sizes="180x180" href="/favicons/apple-touch-icon.png" />
            <link rel="manifest" href="/favicons/site.webmanifest" />
        </head>
        <body className={inter.className}>
        <AuthProvider>
            <Providers>
                {children}
            </Providers>
        </AuthProvider>
        </body>
        </html>
    );
}