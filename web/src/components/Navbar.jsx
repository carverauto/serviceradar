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

// src/components/Navbar.jsx
'use client';

import React, { useState } from 'react';
import Link from 'next/link';
import Image from 'next/image';
import { Sun, Moon, Menu, X, User, LogOut } from 'lucide-react';
import { useTheme } from '@/app/providers';
import { useAuth } from '@/components/AuthProvider';

function Navbar() {
  const { darkMode, setDarkMode } = useTheme();
  const { user, logout, isAuthEnabled } = useAuth();
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);

  const handleToggleDarkMode = () => setDarkMode(!darkMode);
  const toggleMobileMenu = () => setMobileMenuOpen(!mobileMenuOpen);
  const closeMobileMenu = () => setMobileMenuOpen(false);

  return (
      <nav className="bg-white dark:bg-gray-800 shadow-lg transition-colors" onClick={(e) => console.log("Navbar clicked", e)}>
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
                Dashboard
              </Link>
              <Link href="/nodes" className="text-gray-600 dark:text-gray-300 hover:text-gray-800 dark:hover:text-gray-100">
                Nodes
              </Link>
              {isAuthEnabled && (
                  <>
                    {user && (
                        <div className="flex items-center space-x-2">
                          <User className="h-5 w-5 text-gray-600 dark:text-gray-300" />
                          <span className="text-gray-600 dark:text-gray-300">{user.email}</span>
                        </div>
                    )}
                    {user && (
                        <button
                            onClick={logout}
                            className="flex items-center space-x-1 text-gray-600 dark:text-gray-300 hover:text-gray-800 dark:hover:text-gray-100"
                        >
                          <LogOut className="h-5 w-5" />
                          <span>Logout</span>
                        </button>
                    )}
                  </>
              )}
              <button
                  onClick={handleToggleDarkMode}
                  className="p-2 rounded-md bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-200 hover:bg-gray-200 dark:hover:bg-gray-600 border border-gray-300 dark:border-gray-600"
              >
                {darkMode ? <Sun className="h-5 w-5" /> : <Moon className="h-5 w-5" />}
              </button>
            </div>

            <div className="flex md:hidden items-center space-x-2">
              {isAuthEnabled && user && (
                  <button onClick={logout} className="p-2 rounded-md bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-200">
                    <LogOut className="h-5 w-5" />
                  </button>
              )}
              <button
                  onClick={handleToggleDarkMode}
                  className="p-2 rounded-md bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-200 border border-gray-300 dark:border-gray-600"
              >
                {darkMode ? <Sun className="h-5 w-5" /> : <Moon className="h-5 w-5" />}
              </button>
              <button
                  onClick={toggleMobileMenu}
                  className="p-2 rounded-md bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-200 border border-gray-300 dark:border-gray-600"
              >
                {mobileMenuOpen ? <X className="h-5 w-5" /> : <Menu className="h-5 w-5" />}
              </button>
            </div>
          </div>

          {mobileMenuOpen && (
              <div className="md:hidden mt-3 py-2 border-t border-gray-200 dark:border-gray-700">
                <div className="flex flex-col space-y-3">
                  <Link href="/" onClick={closeMobileMenu} className="block px-2 py-1 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700">
                    Dashboard
                  </Link>
                  <Link href="/nodes" onClick={closeMobileMenu} className="block px-2 py-1 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700">
                    Nodes
                  </Link>
                  {isAuthEnabled && user && (
                      <div className="px-2 py-1 text-gray-700 dark:text-gray-300">
                        <User className="h-5 w-5 inline mr-2" />
                        {user.email}
                      </div>
                  )}
                </div>
              </div>
          )}
        </div>
      </nav>
  );
}

export default Navbar;