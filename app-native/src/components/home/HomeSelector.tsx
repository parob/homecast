import { StyleSheet, ScrollView, TouchableOpacity } from 'react-native';
import FontAwesome from '@expo/vector-icons/FontAwesome';

import { Text } from '@/components/Themed';
import type { Home } from '@/types/homekit';

interface Props {
  homes: Home[];
  selectedHomeId: string | null;
  onSelectHome: (homeId: string) => void;
}

export function HomeSelector({ homes, selectedHomeId, onSelectHome }: Props) {
  if (homes.length <= 1) {
    return null;
  }

  return (
    <ScrollView
      horizontal
      showsHorizontalScrollIndicator={false}
      contentContainerStyle={styles.container}
    >
      {homes.map((home) => {
        const isSelected = home.id === selectedHomeId;
        return (
          <TouchableOpacity
            key={home.id}
            style={[styles.homeChip, isSelected && styles.homeChipSelected]}
            onPress={() => onSelectHome(home.id)}
          >
            <FontAwesome
              name={home.isPrimary ? 'home' : 'building'}
              size={14}
              color={isSelected ? '#fff' : '#888'}
            />
            <Text style={[styles.homeText, isSelected && styles.homeTextSelected]}>
              {home.name}
            </Text>
          </TouchableOpacity>
        );
      })}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    paddingHorizontal: 16,
    paddingVertical: 8,
    gap: 8,
    height: 52,
  },
  homeChip: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: '#e5e5ea',
    paddingHorizontal: 14,
    height: 36,
    borderRadius: 18,
    gap: 6,
  },
  homeChipSelected: {
    backgroundColor: '#007AFF',
  },
  homeText: {
    fontSize: 14,
    color: '#3c3c43',
  },
  homeTextSelected: {
    color: '#fff',
    fontWeight: '500',
  },
});
