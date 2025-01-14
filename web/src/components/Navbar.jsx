// src/components/Navbar.jsx
import React from 'react';
import { Link } from 'react-router-dom';

function Navbar() {
  return (
      <nav className="bg-white shadow-lg">
        <div className="container mx-auto px-6 py-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center">
              <Link to="/" className="text-xl font-bold text-gray-800">
                HomeMon
              </Link>
            </div>
            <div className="flex items-center space-x-4">
              <Link to="/" className="text-gray-600 hover:text-gray-800">
                Dashboard
              </Link>
              <Link to="/nodes" className="text-gray-600 hover:text-gray-800">
                Nodes
              </Link>
              <Link to="/dusk" className="text-gray-600 hover:text-gray-800">
                Dusk
              </Link>
            </div>
          </div>
        </div>
      </nav>
  );
}

export default Navbar;