import React from 'react';
import { BrowserRouter as Router, Routes, Route } from 'react-router-dom';
import Navbar from './components/Navbar';
import Dashboard from './components/Dashboard';
import DuskDashboard from './components/DuskDashboard';
import NodeList from './components/NodeList';

function App() {
    return (
        <Router>
            <div className="min-h-screen bg-gray-100">
                <Navbar />
                <main className="container mx-auto px-4 py-8">
                    <Routes>
                        <Route path="/" element={<Dashboard />} />
                        <Route path="/nodes" element={<NodeList />} />
                        <Route path="/dusk" element={<DuskDashboard />} />
                    </Routes>
                </main>
            </div>
        </Router>
    );
}

export default App