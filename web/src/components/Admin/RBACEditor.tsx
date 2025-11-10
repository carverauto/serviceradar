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
import { Plus, Trash2, X } from 'lucide-react';

export interface RBACConfig {
  role_permissions?: Record<string, string[]>;
  route_protection?: Record<string, string[] | Record<string, string[]>>;
  user_roles?: Record<string, string[]>;
}

interface RBACEditorProps {
  value?: RBACConfig;
  onChange: (value: RBACConfig) => void;
}

interface ChipListProps {
  items?: string[];
  placeholder: string;
  addLabel?: string;
  onAdd: (value: string) => void;
  onRemove: (value: string) => void;
  emptyHint?: string;
}

const ChipList = ({ items = [], placeholder, addLabel = 'Add', onAdd, onRemove, emptyHint }: ChipListProps) => {
  return (
    <div className="space-y-2">
      <div className="flex flex-wrap gap-2 min-h-[2.25rem]">
        {items.length === 0 && emptyHint ? (
          <span className="text-sm text-gray-500 dark:text-gray-400">{emptyHint}</span>
        ) : null}
        {items.map((item) => (
          <span
            key={item}
            className="inline-flex items-center gap-1 rounded-full bg-blue-50 text-blue-700 px-3 py-1 text-xs dark:bg-blue-900/30 dark:text-blue-100"
          >
            {item}
            <button
              type="button"
              onClick={() => onRemove(item)}
              className="text-blue-700 hover:text-blue-900 dark:text-blue-200"
              aria-label={`Remove ${item}`}
            >
              <X className="h-3 w-3" />
            </button>
          </span>
        ))}
      </div>
      <InlineAddInput placeholder={placeholder} buttonLabel={addLabel} onSubmit={onAdd} />
    </div>
  );
};

interface InlineAddInputProps {
  placeholder: string;
  buttonLabel?: string;
  onSubmit: (value: string) => void;
}

const InlineAddInput = ({ placeholder, buttonLabel = 'Add', onSubmit }: InlineAddInputProps) => {
  const [value, setValue] = React.useState('');
  const handleSubmit = () => {
    const trimmed = value.trim();
    if (!trimmed) return;
    onSubmit(trimmed);
    setValue('');
  };
  return (
    <div className="flex gap-2">
      <input
        type="text"
        value={value}
        onChange={(e) => setValue(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Enter') {
            e.preventDefault();
            handleSubmit();
          }
        }}
        placeholder={placeholder}
        className="flex-1 rounded border border-gray-300 bg-white px-2 py-1 text-sm dark:border-gray-600 dark:bg-gray-900"
      />
      <button
        type="button"
        onClick={handleSubmit}
        className="inline-flex items-center gap-1 rounded-md bg-blue-600 px-3 py-1 text-sm text-white hover:bg-blue-700"
      >
        <Plus className="h-4 w-4" />
        {buttonLabel}
      </button>
    </div>
  );
};

const isMethodMap = (value: unknown): value is Record<string, string[]> => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return false;
  }
  return true;
};

export default function RBACEditor({ value, onChange }: RBACEditorProps) {
  const rolePermissions = value?.role_permissions ?? {};
  const userRoles = value?.user_roles ?? {};
  const routeProtection = value?.route_protection ?? {};

  const propagate = (patch: Partial<RBACConfig>) => {
    onChange({
      ...(value ?? {}),
      ...patch,
    });
  };

  const ensureUnique = (values: string[], nextValue: string) => {
    if (values.includes(nextValue)) {
      return values;
    }
    return [...values, nextValue];
  };

  const handleAddRole = (role: string) => {
    if (!rolePermissions[role]) {
      propagate({
        role_permissions: {
          ...rolePermissions,
          [role]: [],
        },
      });
    }
  };

  const handleRemoveRole = (role: string) => {
    const next = { ...rolePermissions };
    delete next[role];
    propagate({ role_permissions: next });
  };

  const handleAddPermission = (role: string, permission: string) => {
    const perms = rolePermissions[role] ?? [];
    const next = {
      ...rolePermissions,
      [role]: ensureUnique(perms, permission),
    };
    propagate({ role_permissions: next });
  };

  const handleRemovePermission = (role: string, permission: string) => {
    const perms = rolePermissions[role] ?? [];
    const next = {
      ...rolePermissions,
      [role]: perms.filter((item) => item !== permission),
    };
    propagate({ role_permissions: next });
  };

  const handleAddUser = (userId: string) => {
    if (!userRoles[userId]) {
      propagate({
        user_roles: {
          ...userRoles,
          [userId]: [],
        },
      });
    }
  };

  const handleRemoveUser = (userId: string) => {
    const next = { ...userRoles };
    delete next[userId];
    propagate({ user_roles: next });
  };

  const handleAddUserRole = (userId: string, role: string) => {
    const roles = userRoles[userId] ?? [];
    const next = {
      ...userRoles,
      [userId]: ensureUnique(roles, role),
    };
    propagate({ user_roles: next });
  };

  const handleRemoveUserRole = (userId: string, role: string) => {
    const roles = userRoles[userId] ?? [];
    const next = {
      ...userRoles,
      [userId]: roles.filter((item) => item !== role),
    };
    propagate({ user_roles: next });
  };

  const handleAddRoute = (path: string) => {
    if (!path) return;
    if (routeProtection[path]) return;
    propagate({
      route_protection: {
        ...routeProtection,
        [path]: [],
      },
    });
  };

  const handleRemoveRoute = (path: string) => {
    const next = { ...routeProtection };
    delete next[path];
    propagate({ route_protection: next });
  };

  const handleRouteModeChange = (path: string, mode: 'all' | 'custom') => {
    const current = routeProtection[path];
    if (mode === 'all') {
      let seed: string[] = [];
      if (Array.isArray(current)) {
        seed = current;
      } else if (isMethodMap(current)) {
        const unique = new Set<string>();
        Object.values(current).forEach((roles) => {
          (roles ?? []).forEach((role) => unique.add(role));
        });
        seed = Array.from(unique);
      }
      propagate({
        route_protection: {
          ...routeProtection,
          [path]: seed,
        },
      });
    } else {
      const seed = Array.isArray(current) ? current : [];
      propagate({
        route_protection: {
          ...routeProtection,
          [path]: seed.length ? { GET: seed } : { GET: [] },
        },
      });
    }
  };

  const handleRouteRoleAdd = (path: string, role: string, method?: string) => {
    const base = routeProtection[path];
    if (Array.isArray(base)) {
      propagate({
        route_protection: {
          ...routeProtection,
          [path]: ensureUnique(base, role),
        },
      });
      return;
    }
    const methodKey = (method ?? 'GET').toUpperCase();
    const current = isMethodMap(base) ? base : {};
    const existing = current[methodKey] ?? [];
    const next: Record<string, string[]> = {
      ...current,
      [methodKey]: ensureUnique(existing, role),
    };
    propagate({
      route_protection: {
        ...routeProtection,
        [path]: next,
      },
    });
  };

  const handleRouteRoleRemove = (path: string, role: string, method?: string) => {
    const base = routeProtection[path];
    if (Array.isArray(base)) {
      propagate({
        route_protection: {
          ...routeProtection,
          [path]: base.filter((item) => item !== role),
        },
      });
      return;
    }
    if (!isMethodMap(base)) return;
    const methodKey = (method ?? 'GET').toUpperCase();
    const current = base[methodKey] ?? [];
    const nextMap: Record<string, string[]> = { ...base };
    const filtered = current.filter((item) => item !== role);
    nextMap[methodKey] = filtered;
    propagate({
      route_protection: {
        ...routeProtection,
        [path]: nextMap,
      },
    });
  };

  const handleAddRouteMethod = (path: string, method: string) => {
    const methodKey = method.toUpperCase();
    const base = routeProtection[path];
    const normalized = isMethodMap(base) ? base : {};
    if (normalized[methodKey]) {
      return;
    }
    propagate({
      route_protection: {
        ...routeProtection,
        [path]: {
          ...normalized,
          [methodKey]: [],
        },
      },
    });
  };

  const handleRemoveRouteMethod = (path: string, method: string) => {
    const base = routeProtection[path];
    if (!isMethodMap(base)) return;
    const methodKey = method.toUpperCase();
    const nextMap = { ...base };
    delete nextMap[methodKey];
    if (Object.keys(nextMap).length === 0) {
      nextMap.GET = [];
    }
    propagate({
      route_protection: {
        ...routeProtection,
        [path]: nextMap,
      },
    });
  };

  return (
    <div className="space-y-8">
      <section>
        <div className="flex items-center justify-between">
          <h4 className="text-md font-semibold">Role permissions</h4>
          <InlineAddInput placeholder="Add role (e.g., operator)" buttonLabel="Add role" onSubmit={handleAddRole} />
        </div>
        {Object.keys(rolePermissions).length === 0 ? (
          <p className="mt-3 rounded border border-dashed border-gray-300 p-4 text-sm text-gray-500 dark:border-gray-700 dark:text-gray-400">
            Define roles and the permissions they unlock.
          </p>
        ) : (
          <div className="mt-4 space-y-4">
            {Object.entries(rolePermissions).map(([role, permissions]) => (
              <div key={role} className="rounded-lg border border-gray-200 p-4 dark:border-gray-700">
                <div className="mb-3 flex items-center justify-between">
                  <div>
                    <p className="font-medium">{role}</p>
                    <p className="text-xs text-gray-500 dark:text-gray-400">
                      Permissions granted to this role
                    </p>
                  </div>
                  <button
                    type="button"
                    onClick={() => handleRemoveRole(role)}
                    className="inline-flex items-center gap-1 rounded-md border border-red-200 px-2 py-1 text-xs text-red-600 hover:bg-red-50 dark:border-red-900/30 dark:text-red-200 dark:hover:bg-red-900/30"
                  >
                    <Trash2 className="h-3.5 w-3.5" />
                    Remove
                  </button>
                </div>
                <ChipList
                  items={permissions}
                  placeholder="Add permission (e.g., config:read)"
                  onAdd={(value) => handleAddPermission(role, value)}
                  onRemove={(value) => handleRemovePermission(role, value)}
                  emptyHint="No permissions assigned yet."
                />
              </div>
            ))}
          </div>
        )}
      </section>

      <section>
        <div className="flex items-center justify-between">
          <h4 className="text-md font-semibold">User role assignments</h4>
          <InlineAddInput placeholder="Add user/identity (e.g., admin)" buttonLabel="Add user" onSubmit={handleAddUser} />
        </div>
        {Object.keys(userRoles).length === 0 ? (
          <p className="mt-3 rounded border border-dashed border-gray-300 p-4 text-sm text-gray-500 dark:border-gray-700 dark:text-gray-400">
            Map identities to roles. Keys can be usernames, emails, or provider-qualified IDs.
          </p>
        ) : (
          <div className="mt-4 space-y-4">
            {Object.entries(userRoles).map(([userId, roles]) => (
              <div key={userId} className="rounded-lg border border-gray-200 p-4 dark:border-gray-700">
                <div className="mb-3 flex items-center justify-between">
                  <div>
                    <p className="font-medium">{userId}</p>
                    <p className="text-xs text-gray-500 dark:text-gray-400">Roles assigned to this identity</p>
                  </div>
                  <button
                    type="button"
                    onClick={() => handleRemoveUser(userId)}
                    className="inline-flex items-center gap-1 rounded-md border border-red-200 px-2 py-1 text-xs text-red-600 hover:bg-red-50 dark:border-red-900/30 dark:text-red-200 dark:hover:bg-red-900/30"
                  >
                    <Trash2 className="h-3.5 w-3.5" />
                    Remove
                  </button>
                </div>
                <ChipList
                  items={roles}
                  placeholder="Add role"
                  onAdd={(value) => handleAddUserRole(userId, value)}
                  onRemove={(value) => handleRemoveUserRole(userId, value)}
                  emptyHint="No roles assigned."
                />
              </div>
            ))}
          </div>
        )}
      </section>

      <section>
        <div className="flex items-center justify-between">
          <h4 className="text-md font-semibold">Route protection</h4>
          <InlineAddInput placeholder="Add route (e.g., /api/devices/*)" buttonLabel="Add route" onSubmit={handleAddRoute} />
        </div>
        {Object.keys(routeProtection).length === 0 ? (
          <p className="mt-3 rounded border border-dashed border-gray-300 p-4 text-sm text-gray-500 dark:border-gray-700 dark:text-gray-400">
            Guard API prefixes with role requirements. Use wildcards such as <code className="px-1">/api/admin/*</code>.
          </p>
        ) : (
          <div className="mt-4 space-y-4">
            {Object.entries(routeProtection).map(([path, entry]) => {
              const mode = Array.isArray(entry) ? 'all' : 'custom';
              const methodMapRaw = isMethodMap(entry) ? entry : {};
              const normalizedMethodMap = Object.entries(methodMapRaw).reduce<Record<string, string[]>>(
                (acc, [method, roles]) => {
                  if (Array.isArray(roles)) {
                    acc[method.toUpperCase()] = roles;
                  }
                  return acc;
                },
                {},
              );
              const methodOrder = Object.keys(normalizedMethodMap);

              return (
                <div key={path} className="rounded-lg border border-gray-200 p-4 dark:border-gray-700">
                  <div className="mb-3 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
                    <div>
                      <p className="font-medium">{path}</p>
                      <div className="mt-2 flex flex-wrap gap-4 text-xs text-gray-600 dark:text-gray-400">
                        <label className="inline-flex items-center gap-1">
                          <input
                            type="radio"
                            checked={mode === 'all'}
                            onChange={() => handleRouteModeChange(path, 'all')}
                          />
                          <span>All methods share these roles</span>
                        </label>
                        <label className="inline-flex items-center gap-1">
                          <input
                            type="radio"
                            checked={mode === 'custom'}
                            onChange={() => handleRouteModeChange(path, 'custom')}
                          />
                          <span>Define per-method roles</span>
                        </label>
                      </div>
                    </div>
                    <button
                      type="button"
                      onClick={() => handleRemoveRoute(path)}
                      className="inline-flex items-center gap-1 rounded-md border border-red-200 px-2 py-1 text-xs text-red-600 hover:bg-red-50 dark:border-red-900/30 dark:text-red-200 dark:hover:bg-red-900/30"
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                      Remove route
                    </button>
                  </div>

                  {mode === 'all' ? (
                    <ChipList
                      items={Array.isArray(entry) ? entry : []}
                      placeholder="Add role allowed on this route"
                      addLabel="Add role"
                      onAdd={(value) => handleRouteRoleAdd(path, value)}
                      onRemove={(value) => handleRouteRoleRemove(path, value)}
                      emptyHint="No roles assigned yet."
                    />
                  ) : (
                    <div className="space-y-4">
                      {methodOrder.map((method) => {
                        const roles = normalizedMethodMap[method] ?? [];
                        return (
                          <div key={`${path}-${method}`} className="rounded border border-gray-100 p-3 dark:border-gray-800">
                            <div className="mb-2 flex items-center justify-between text-sm font-medium">
                              <span>{method}</span>
                              <button
                                type="button"
                                onClick={() => handleRemoveRouteMethod(path, method)}
                                className="text-xs text-gray-500 hover:text-gray-700 disabled:cursor-not-allowed disabled:opacity-50 dark:text-gray-400 dark:hover:text-gray-200"
                                disabled={methodOrder.length <= 1}
                              >
                                Remove method
                              </button>
                            </div>
                            <ChipList
                              items={roles}
                              placeholder="Add role"
                              addLabel="Add role"
                              onAdd={(value) => handleRouteRoleAdd(path, value, method)}
                              onRemove={(value) => handleRouteRoleRemove(path, value, method)}
                              emptyHint="No roles assigned."
                            />
                          </div>
                        );
                      })}
                      <InlineAddInput
                        placeholder="Add HTTP method (e.g., OPTIONS)"
                        buttonLabel="Add method"
                        onSubmit={(method) => handleAddRouteMethod(path, method)}
                      />
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </section>
    </div>
  );
}
