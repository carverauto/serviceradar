'use client';

import React, { useState, useEffect, useRef } from 'react';
import Link from 'next/link';
import Image from 'next/image';
import { Sun, Moon, Menu, X, User, LogOut, ChevronDown, SlidersHorizontal } from 'lucide-react';
import { useTheme } from '@/app/providers';
import { useAuth } from '@/components/AuthProvider';

function Navbar() {
  const { darkMode, setDarkMode } = useTheme();
  const { user, logout, isAuthEnabled } = useAuth();
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);
  const [dropdownOpen, setDropdownOpen] = useState(false);
  const dropdownRef = useRef(null);

  const handleToggleDarkMode = () => {
    setDarkMode(!darkMode);
  };
  const toggleMobileMenu = () => setMobileMenuOpen(!mobileMenuOpen);
  const toggleDropdown = () => setDropdownOpen(!dropdownOpen);

  useEffect(() => {
    const handleClickOutside = (event) => {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target)) {
        setDropdownOpen(false);
      }
    };

    if (dropdownOpen) {
      document.addEventListener('mousedown', handleClickOutside);
    }

    return () => {
      document.removeEventListener('mousedown', handleClickOutside);
    };
  }, [dropdownOpen]);

  return (
      <nav className="bg-white dark:bg-gray-800 shadow-lg transition-colors">
        <div className="container mx-auto px-4 py-3">
          <div className="flex items-center justify-between">
            <div className="flex items-center">
              <Image src="/serviceRadar.svg" alt="logo" width={36} height={36} />
              <Link href="/" className="text-xl font-bold text-gray-800 dark:text-gray-200 ml-2">
                ServiceRadar
              </Link>
            </div>

            <div className="hidden md:flex items-center space-x-6">
              <Link href="/" className="text-gray-600 dark:text-gray-300 hover:text-gray-800 dark:hover:text-gray-100">
                Home
              </Link>
              <Link href="/dashboard" className="text-gray-600 dark:text-gray-300 hover:text-gray-800 dark:hover:text-gray-100">
                Dashboard
              </Link>
              <Link href="/pollers" className="text-gray-600 dark:text-gray-300 hover:text-gray-800 dark:hover:text-gray-100">
                Pollers
              </Link>
              <div className="relative" ref={dropdownRef}>
                <button
                    onClick={toggleDropdown}
                    className="flex items-center text-gray-600 dark:text-gray-300 hover:text-gray-800 dark:hover:text-gray-100"
                >
                  <SlidersHorizontal className="h-5 w-5 mr-1" />
                  <ChevronDown className="h-4 w-4" />
                </button>
                {dropdownOpen && (
                    <div className="absolute top-full right-0 mt-2 w-48 bg-white dark:bg-gray-700 border border-gray-200 dark:border-gray-600 rounded-md shadow-lg z-10">
                      <Link
                          href="/query"
                          className="block px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-600"
                          onClick={() => setDropdownOpen(false)} // Close dropdown on click
                      >
                        Query Tool
                      </Link>
                      <Link
                          href="/swagger/index.html"
                          className="block px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-600"
                      >
                        API Docs
                      </Link>
                      <button
                          onClick={handleToggleDarkMode}
                          className="w-full text-left px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-600 flex items-center space-x-2"
                      >
                        {darkMode ? <Sun className="h-5 w-5" /> : <Moon className="h-5 w-5" />}
                        <span>{darkMode ? 'Light Mode' : 'Dark Mode'}</span>
                      </button>
                      {isAuthEnabled && user && (
                          <>
                            <div className="px-4 py-2 text-gray-700 dark:text-gray-300 border-t border-gray-200 dark:border-gray-600">
                              <User className="h-5 w-5 inline mr-2" />
                              {user.email}
                            </div>
                            <button
                                onClick={logout}
                                className="w-full text-left px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-600 flex items-center space-x-2"
                            >
                              <LogOut className="h-5 w-5" />
                              <span>Logout</span>
                            </button>
                          </>
                      )}
                    </div>
                )}
              </div>
            </div>

            <div className="flex md:hidden items-center space-x-2">
              <button
                  onClick={toggleMobileMenu}
                  className="p-2 rounded-md bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-200 border border-gray-300 dark:border-gray-600"
              >
                {mobileMenuOpen ? <X className="h-5 w-5" /> : <Menu className="h-5 w-5" />}
              </button>
            </div>
          </div>

          {mobileMenuOpen && (
              <div className="md:hidden mt-3 py-2 border-t border-gray-200 dark:border-gray-700 w-full overflow-x-auto">
                <div className="flex flex-col space-y-3">
                  <Link href="/" onClick={() => {}} className="block px-2 py-1 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700">
                    Home
                  </Link>
                  <Link href="/dashboard" onClick={() => {}} className="block px-2 py-1 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700">
                    Dashboard
                  </Link>
                  <Link href="/pollers" onClick={() => {}} className="block px-2 py-1 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700">
                    Pollers
                  </Link>
                  <Link href="/query" onClick={toggleMobileMenu} className="block px-2 py-1 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700">
                    Query Tool
                  </Link>
                  <Link href="/swagger/index.html" onClick={() => {}} className="block px-2 py-1 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700">
                    API Docs
                  </Link>
                  <button
                      onClick={handleToggleDarkMode}
                      className="block px-2 py-1 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 flex items-center space-x-2"
                  >
                    {darkMode ? <Sun className="h-5 w-5" /> : <Moon className="h-5 w-5" />}
                    <span>{darkMode ? 'Light Mode' : 'Dark Mode'}</span>
                  </button>
                  {isAuthEnabled && user && (
                      <>
                        <div className="px-2 py-1 text-gray-700 dark:text-gray-300 flex items-center space-x-2">
                          <User className="h-5 w-5" />
                          <span className="truncate">{user.email}</span>
                        </div>
                        <button
                            onClick={logout}
                            className="block px-2 py-1 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 flex items-center space-x-2"
                        >
                          <LogOut className="h-5 w-5" />
                          <span>Logout</span>
                        </button>
                      </>
                  )}
                </div>
              </div>
          )}
        </div>
      </nav>
  );
}

export default Navbar;