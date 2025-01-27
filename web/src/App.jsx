import React from 'react';
import { BrowserRouter as Router, Routes, Route } from 'react-router-dom';
import Navbar from './components/Navbar';
import Dashboard from './components/Dashboard';
import NodeList from './components/NodeList';
import ServiceDashboard from './components/ServiceDashboard';

function App() {
    return (
        <Router>
            <div className="min-h-screen bg-gray-100">
                <Navbar />
                <main className="container mx-auto px-4 py-8">
                    <Routes>
                        <Route path="/" element={<Dashboard />} />
                        <Route path="/nodes" element={<NodeList />} />
                        <Route path="/service/:nodeId/:serviceName" element={<ServiceDashboard />} />
                    </Routes>
                </main>
            </div>
        </Router>
    );
}

export default App;