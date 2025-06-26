import './globals.css';
import { AuthProvider } from '@/components/AuthProvider';
import Header from '@/components/Header';
import { Providers } from './providers';
import Sidebar from '@/components/Sidebar';

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
                <div className="flex h-screen overflow-hidden">
                    <Sidebar />
                    <div className="flex-1 flex flex-col">
                        <Header />
                        <main className="flex-1 p-6 overflow-y-auto">
                            {children}
                        </main>
                    </div>
                </div>
            </AuthProvider>
        </Providers>
        </body>
        </html>
    );
}