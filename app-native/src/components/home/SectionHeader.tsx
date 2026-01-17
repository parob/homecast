import React from 'react';
import { StyleSheet, TouchableOpacity, View } from 'react-native';
import Ionicons from '@expo/vector-icons/Ionicons';
import { Text } from '@/components/Themed';

interface SectionHeaderProps {
  title: string;
  onPress?: () => void;
}

export function SectionHeader({ title, onPress }: SectionHeaderProps) {
  const content = (
    <View style={styles.container}>
      <Text style={styles.title}>{title}</Text>
      {onPress && <Ionicons name="chevron-forward" size={20} color="rgba(0,0,0,0.2)" />}
    </View>
  );

  if (onPress) {
    return (
      <TouchableOpacity onPress={onPress} activeOpacity={0.7}>
        {content}
      </TouchableOpacity>
    );
  }

  return content;
}

const styles = StyleSheet.create({
  container: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 16,
    paddingTop: 24,
    paddingBottom: 10,
  },
  title: {
    fontSize: 18,
    fontWeight: '600',
    color: '#000000',
    letterSpacing: -0.3,
  },
});
