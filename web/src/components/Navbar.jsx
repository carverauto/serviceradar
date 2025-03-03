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

'use client';

import React from 'react';
import Link from 'next/link';
import Image from 'next/image';
import { Sun, Moon } from 'lucide-react';
import { useTheme } from '@/app/providers';

function Navbar() {
  const { darkMode, setDarkMode } = useTheme();

  const handleToggleDarkMode = () => {
    setDarkMode(!darkMode);
  };

  return (
      <nav className="bg-white dark:bg-gray-800 shadow-lg transition-colors">
        <div className="container mx-auto px-6 py-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center">
              <Image src="/serviceRadar.svg" alt="logo" width={40} height={40} />
              <Link
                  href="/"
                  className="text-xl font-bold text-gray-800 dark:text-gray-200 ml-2 transition-colors"
              >
                ServiceRadar
              </Link>
            </div>
            <div className="flex items-center space-x-4">
              <Link
                  href="/"
                  className="text-gray-600 dark:text-gray-300 hover:text-gray-800 dark:hover:text-gray-100 transition-colors"
              >
                Dashboard
              </Link>
              <Link
                  href="/nodes"
                  className="text-gray-600 dark:text-gray-300 hover:text-gray-800 dark:hover:text-gray-100 transition-colors"
              >
                Nodes
              </Link>
              {/* Dark mode toggle icon */}
              <button
                  onClick={handleToggleDarkMode}
                  className="inline-flex items-center justify-center p-2
                     rounded-md transition-colors
                     bg-gray-100 dark:bg-gray-700
                     hover:bg-gray-200 dark:hover:bg-gray-600
                     text-gray-600 dark:text-gray-200
                     border border-gray-300 dark:border-gray-600"
                  aria-label="Toggle Dark Mode"
              >
                {darkMode ? (
                    <Sun className="h-5 w-5" />
                ) : (
                    <Moon className="h-5 w-5" />
                )}
              </button>
            </div>
          </div>
        </div>
      </nav>
  );
}

export default Navbar;