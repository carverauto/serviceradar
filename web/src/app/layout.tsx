import './globals.css';
import { AuthProvider } from '@/components/utils/AuthProvider';
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
        <html lang="en" className="dark" style={{ colorScheme: 'dark' }}>
        <body className="bg-[#1C1B22]">
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