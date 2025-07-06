import './globals.css';
import { AuthProvider } from '@/components/AuthProvider';
import { Providers } from './providers';
import LayoutWrapper from '@/components/LayoutWrapper';

export const metadata = {
    title: 'ServiceRadar',
    description: 'Network Monitoring and Analytics Platform',
};

export default function RootLayout({
                                       children,
                                   }: {
    children: React.ReactNode;
}) {
    return (
        <html lang="en">
        <body className="bg-gray-50 dark:bg-gray-900 text-gray-900 dark:text-white">
        <Providers>
            <AuthProvider>
                <LayoutWrapper>
                    {children}
                </LayoutWrapper>
            </AuthProvider>
        </Providers>
        </body>
        </html>
    );
}