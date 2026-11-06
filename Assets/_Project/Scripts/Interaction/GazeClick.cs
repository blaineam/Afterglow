using System;
using UnityEngine;
using UnityEngine.EventSystems;

namespace Afterglow.Interaction
{
    // Passes a gaze click (a screen tap, or a pinch that nothing else took) on this collider to
    // whoever listens: the way a scene object, such as the browser's window, takes a tap. Goes on
    // the object with the collider.
    public class GazeClick : MonoBehaviour, IPointerClickHandler
    {
        public event Action Clicked;

        public void OnPointerClick(PointerEventData eventData) => Clicked?.Invoke();
    }
}
