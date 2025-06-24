'use client';

import React, { useState } from 'react';
import Link from 'next/link';
import { Menu, Sun, Moon } from 'lucide-react';
import { useTheme } from '@/app/providers';

export default function Sidebar() {
  const { darkMode, setDarkMode } = useTheme();
  const [open, setOpen] = useState(false);

  const toggleOpen = () => setOpen(!open);
  const toggleDarkMode = () => setDarkMode(!darkMode);

  return (
    <div className={`flex flex-col border-r dark:border-gray-700 bg-white dark:bg-gray-800 transition-all duration-300 ${open ? 'w-64' : 'w-16'}`}> 
      <button onClick={toggleOpen} className="p-4 focus:outline-none">
        <Menu className="h-5 w-5" />
      </button>
      <nav className="flex-1 px-2 space-y-2">
        <Link href="/" className="block px-2 py-2 rounded hover:bg-gray-100 dark:hover:bg-gray-700">
          Home
        </Link>
        <Link href="/dashboard" className="block px-2 py-2 rounded hover:bg-gray-100 dark:hover:bg-gray-700">
          Dashboard
        </Link>
        <Link href="/pollers" className="block px-2 py-2 rounded hover:bg-gray-100 dark:hover:bg-gray-700">
          Pollers
        </Link>
        <Link href="/query" className="block px-2 py-2 rounded hover:bg-gray-100 dark:hover:bg-gray-700">
          Query Tool
        </Link>
        <Link href="/swagger/index.html" className="block px-2 py-2 rounded hover:bg-gray-100 dark:hover:bg-gray-700">
          API Docs
        </Link>
      </nav>
      <button onClick={toggleDarkMode} className="p-4 border-t dark:border-gray-700 hover:bg-gray-100 dark:hover:bg-gray-700">
        {darkMode ? <Sun className="h-5 w-5" /> : <Moon className="h-5 w-5" />}
      </button>
    </div>
  );
}
