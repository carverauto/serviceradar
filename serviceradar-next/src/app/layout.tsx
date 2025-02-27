import './globals.css';
import { Inter } from 'next/font/google';
import { Providers } from './providers';
import { ReactNode } from 'react'; // Import ReactNode

const inter = Inter({ subsets: ['latin'] });

export const metadata = {
    title: 'ServiceRadar',
    description: 'Monitor your network services',
};

// Define the props type for RootLayout
interface RootLayoutProps {
    children: ReactNode; // Explicitly type children
}

export default function RootLayout({ children }: RootLayoutProps) {
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
        <Providers>
            {children}
        </Providers>
        </body>
        </html>
    );
}