import React, {useEffect, useState} from 'react';
import { BrowserRouter as Router, Routes, Route } from 'react-router-dom';
import Navbar from './components/Navbar';
import Dashboard from './components/Dashboard';
import NodeList from './components/NodeList';
import ServiceDashboard from './components/ServiceDashboard';

function App() {
    const [darkMode, setDarkMode] = useState(false);

    // remember user preference in localStorage
    useEffect(() => {
        const savedMode = localStorage.getItem('darkMode');
        if (savedMode) {
            setDarkMode(savedMode === 'true');
        }
    }, [])

    useEffect(() => {
        localStorage.setItem('darkMode', darkMode);
    }, [darkMode])

    return (
        <div className={darkMode ? 'dark' : ''}>
            <Router>
                <div className="min-h-screen bg-gray-100 dark:bg-gray-900 transition-colors">
                    <Navbar darkMode={darkMode} setDarkMode={setDarkMode} />
                    <main className="container mx-auto px-4 py-8">
                        <Routes>
                            <Route path="/" element={<Dashboard />} />
                            <Route path="/nodes" element={<NodeList />} />
                            <Route path="/service/:nodeId/:serviceName" element={<ServiceDashboard />} />
                        </Routes>
                    </main>
                </div>
            </Router>
        </div>
            );
            }

export default App;