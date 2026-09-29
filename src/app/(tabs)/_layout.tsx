import Ionicons from '@expo/vector-icons/Ionicons';
import { Tabs } from 'expo-router';
import type { ComponentProps } from 'react';
import type { ColorValue } from 'react-native';

import { colors, fonts } from '@/theme';

type IconName = ComponentProps<typeof Ionicons>['name'];

function icon(name: IconName, active: IconName) {
  return function TabIcon({ color, focused }: { color: ColorValue; focused: boolean }) {
    return <Ionicons name={focused ? active : name} size={22} color={color} />;
  };
}

export default function TabsLayout() {
  return (
    <Tabs
      screenOptions={{
        headerShown: false,
        tabBarActiveTintColor: colors.accent,
        tabBarInactiveTintColor: colors.textSecondary,
        tabBarStyle: { backgroundColor: colors.background, borderTopColor: colors.border },
        tabBarLabelStyle: { fontFamily: fonts.bodyMedium, fontSize: 11 },
      }}
    >
      <Tabs.Screen name="index" options={{ title: 'Explorar', tabBarIcon: icon('search-outline', 'search') }} />
      <Tabs.Screen
        name="bookings"
        options={{ title: 'Reservas', tabBarIcon: icon('receipt-outline', 'receipt') }}
      />
      <Tabs.Screen
        name="garage"
        options={{ title: 'Mis vehículos', tabBarIcon: icon('key-outline', 'key') }}
      />
      <Tabs.Screen name="profile" options={{ title: 'Perfil', tabBarIcon: icon('person-outline', 'person') }} />
    </Tabs>
  );
}
